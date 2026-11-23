#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// Real welcome lifecycle and tool transport, with an injected text-only generator and the
  /// Relay suite's fake CLI. This never reads a live provider or the person's library.
  @MainActor static func conversationalWelcome(
    browser: BrowserModel, relay: RelayOrchestrator, record: (String) -> [String: Any]?
  ) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
      guard condition else { throw SereinError.invalid("FAIL: " + message) }
      results.append("PASS: " + message)
    }
    func settle() async throws {
      let deadline = Date().addingTimeInterval(10)
      while (relay.welcoming || relay.working) && Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      try check(!relay.welcoming && !relay.working, "Conversation fixture settled")
    }
    let agent = relay.agent
    let savedState = relay.state
    let savedChats = agent.conversations
    let selected = agent.conversationID
    let taskDraft = agent.draft
    let surface = SereinSurface.main
    let draft = surface.draft
    let guideEvidence = GuideCenter.shared.state.done
    let hintEvidence = HintCenter.shared.messageEvidenceForChecks.inWindow
    // A later chat: the first launch's own greeting cancels this welcome (`welcomeIfVisible`).
    let wasWelcomed = WelcomeFlowView.welcomed
    RelayOrchestrator.setSetting(true, forKey: WelcomeFlowView.welcomedKey)
    // Read marks change as the chat is read; they are not a setting.
    func settings() -> [String: Any] {
      UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain).filter { $0.key != "serein.chatReadMarks" }
    }
    let controls = settings()
    let approval = relay.level
    let checkIns = relay.proactiveLevel
    defer {
      RelayOrchestrator.setSetting(wasWelcomed, forKey: WelcomeFlowView.welcomedKey)
      relay.cancelWelcome()
      for topic in relay.setupOffersHere { relay.dismissSetupOffer(topic) }
      relay.restoreWelcomeCheckState(savedState)
      agent.conversations = savedChats
      surface.draft = draft
      try? browser.library.save(savedChats, to: "sessions/threads.json")
    }
    surface.draft = ""
    relay.newChat()
    var calls = 0
    let opening = "Hello from the welcome fixture. What would you like to work on?"
    let generate: SereinWelcome.Generator = {
      calls += 1
      try await Task.sleep(for: .milliseconds(30))
      return opening
    }
    relay.welcomeForChecks(generate: generate)
    relay.welcomeForChecks(generate: generate)
    try await settle()
    relay.welcomeForChecks(generate: generate)
    let stored = browser.library.load([Conversation].self, from: "sessions/threads.json")?
      .first { $0.id == relay.threadID }
    try check(calls == 1 && relay.transcript.count == 1 && relay.transcript.first?.text == opening
      && relay.transcript.first?.role == "assistant" && stored?.messages.first?.text == opening
      && stored?.serein == true && agent.conversationID == selected && agent.draft == taskDraft,
      "Welcome is generated once, saved as an assistant reply and leaves the selected task unchanged")
    try check(GuideCenter.shared.state.done == guideEvidence
      && HintCenter.shared.messageEvidenceForChecks.inWindow == hintEvidence
      && relay.level == approval && relay.proactiveLevel == checkIns,
      "An automatic welcome changes no human progress, approvals or check-in consent")

    relay.newChat()
    surface.draft = "My unsent message"
    relay.welcomeForChecks { calls += 1; return "Must not replace a draft" }
    try check(!relay.welcoming && relay.transcript.isEmpty && calls == 1,
      "Welcome waits while the person has a draft")
    surface.draft = ""
    relay.welcomeForChecks {
      try? await Task.sleep(for: .milliseconds(120)) // Deliberately ignores cancellation.
      return "STALE WELCOME"
    }
    relay.ask("WARM PING welcome cancellation")
    try await settle()
    try await Task.sleep(for: .milliseconds(150))
    try check(relay.transcript.contains { $0.role == "you" && $0.text.contains("welcome cancellation") }
      && !relay.transcript.contains { $0.text == "STALE WELCOME" },
      "A real message cancels the welcome and a late result never overwrites it")

    relay.newChat()
    let abandoned = relay.threadID
    relay.welcomeForChecks {
      try? await Task.sleep(for: .milliseconds(100))
      return "WELCOME FOR OLD CHAT"
    }
    relay.newChat()
    try await Task.sleep(for: .milliseconds(130))
    try check(relay.transcript.isEmpty && !relay.welcoming
      && !agent.conversations.contains { $0.id == abandoned },
      "Changing chats cancels an in-flight welcome without saving a stale chat")
    relay.welcomeForChecks { throw SereinError.invalid("Synthetic unavailable provider") }
    try await settle()
    try check(relay.transcript.count == 1 && relay.transcript.first?.role == "assistant"
      && relay.transcript.first?.notice == true,
      "Unavailable welcome generation falls back to an honest local opening")

    relay.newChat()
    var transientCalls = 0
    let transient: SereinWelcome.Generator = {
      transientCalls += 1
      try await Task.sleep(for: .seconds(2))
      return "Transient greeting"
    }
    relay.welcomeForChecks(generate: transient)
    try await Task.sleep(for: .milliseconds(20))
    relay.cancelWelcome()
    relay.welcomeForChecks(generate: transient)
    try await settle()
    try check(transientCalls == 1 && relay.transcript.count == 1 && relay.transcript.first?.notice == true,
      "Returning after transient cancellation gets a local welcome without a second provider call")
    relay.newChat()
    relay.welcomeForChecks(generate: transient)
    relay.cancelWelcome(suppress: true)
    relay.welcomeForChecks(generate: transient)
    try check(!relay.welcoming && relay.transcript.isEmpty,
      "Explicit Stop prevents the welcome from restarting on later visibility events")
    relay.newChat()
    relay.welcomeForChecks(generate: transient)
    relay.ask("stop")
    relay.welcomeForChecks(generate: transient)
    try check(!relay.welcoming && relay.transcript.isEmpty,
      "Typing stop suppresses the welcome even without an AgentRun")

    relay.newChat()
    relay.ask("SETUP OFFER HUMAN")
    try await settle()
    let offered = record("setup_offer")?["setup_offer"] as? [String: Any]
    try check(relay.setupOffersHere == [.anywhere] && offered?["settings_changed"] as? Bool == false
      && relay.level == approval && relay.proactiveLevel == checkIns
      && NSDictionary(dictionary: controls).isEqual(to: settings()),
      "The real setup tool offers a native card without changing any setting")
    relay.dismissSetupOffer(.anywhere)
    try check(relay.dismissedSetupOffersHere == [.anywhere]
      && RelayPrompt.volatile(request: "Continue my task").contains("Setup offers the person dismissed in this chat: anywhere"),
      "Not now remains visible to the assistant as declined setup context")
    relay.newChat()
    relay.ask("SETUP OFFER AUTOMATIC", inWindow: false, userMessage: false)
    try await settle()
    let denied = record("setup_denied")?["setup_denied"] as? [String: Any]
    try check(relay.setupOffersHere.isEmpty && denied?["error"] != nil,
      "Automatic turns cannot offer setup controls or enable check-ins")
    results += try await conversationalChatSetup(browser: browser, relay: relay, record: record)
    results += try scheduleCost()
    results += try automaticTurns()
    results += try oneConversation()
    results += try questionStyles()
    results += try routineGrants()
    results += try proactiveIdeas()
    return results
  }
}
#endif
