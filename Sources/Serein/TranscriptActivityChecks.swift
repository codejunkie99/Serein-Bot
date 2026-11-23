#if DEBUG
import AppKit
import SereinCore

/// Synthetic native stores exercise the production event monitor, persistence and #170 images.
@MainActor func checkTranscriptActivities() async throws {
  func check(_ value: Bool, _ label: String) throws {
    guard value else { throw SereinError.invalid(label) }
    print("PASS: " + label); fflush(stdout)
  }
  func until(_ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(8)
    while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    return condition()
  }
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("serein-transcript-\(UUID().uuidString)")
  defer { try? fm.removeItem(at: root) }
  let browser = try BrowserModel(root: root)
  defer { browser.shutdown() }
  let agent = AgentModel(browser: browser, discoverProviders: false)
  for driver in [HarnessDriver.claude, .codex] {
    let file = root.appendingPathComponent("\(driver.rawValue)/nested/session.jsonl")
    let id = UUID().uuidString
    let link = SessionLink(driver: driver.rawValue, nativeID: id, file: file.path)
    // Codex uses thread/read in production; this substitutes only its returned JSON, with the
    // real filesystem monitor and publication path still responsible for every update.
    agent.linked = LinkedSessionMonitor(agent: agent, read: { _ in
      let data = try Data(contentsOf: file)
      var history = driver == .claude ? LinkedHistory.claude(data)
        : LinkedHistory.codex(try JSONSerialization.jsonObject(with: data) as! [String: Any])
      history.path = file.path
      return history
    })
    func contents(action: Bool, final: Bool) throws -> Data {
      if driver == .codex {
        var items: [[String: Any]] = [["type": "userMessage", "content": [["type": "text", "text": "Inspect"]]]]
        if action { items.append(["type": "commandExecution", "id": "call", "command": "swift build", "status": "completed"]) }
        if final { items.append(["type": "agentMessage", "text": "Done", "phase": "final_answer"]) }
        return try JSONSerialization.data(withJSONObject: ["path": file.path, "turns": [["status": final ? "completed" : "inProgress", "items": items]]])
      }
      var lines: [[String: Any]] = [["type": "user", "message": ["content": "Inspect"]]]
      if action { lines.append(["type": "assistant", "message": ["id": "a", "content": [["type": "tool_use", "id": "call", "name": "Bash", "input": ["command": "swift build"]]]]]) }
      if final { lines.append(["type": "assistant", "message": ["id": "b", "content": [["type": "text", "text": "Done"]]]]) }
      return try lines.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(Data()) { $0 + $1 + Data([10]) }
    }
    var conversation = Conversation(id: UUID().uuidString, title: "Synthetic", messages: [AgentMessage(role: "you", text: "Inspect")],
      provider: Provider(driver), mode: .answer, projectID: nil, remoteID: id, scope: AgentModel.adoptScope(Provider(driver)), updatedAt: Date(), link: link)
    agent.conversations.insert(conversation, at: 0)
    agent.restore(conversation)
    try check(await until { agent.linked.problem != nil }, "\(driver): a missing log reports a read error")
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents(action: true, final: false).write(to: file)
    try check(await until { agent.messages.last?.activities?.count == 1 && agent.linked.problem == nil },
      "\(driver): creating a delayed log publishes action-only activity without manual refresh")
    let messageID = agent.messages.last!.id
    agent.messages[agent.messages.count - 1].images = ["chat-images/synthetic.png"]
    try contents(action: true, final: true).write(to: file, options: .atomic)
    try check(await until { agent.messages.last?.text == "Done" }, "\(driver): an idle final reply arrives after atomic log replacement")
    try check(agent.messages.last?.id == messageID && agent.messages.last?.images == ["chat-images/synthetic.png"]
      && agent.messages.last?.activities?.count == 1, "\(driver): images, actions and message identity survive reply updates")
    let stored = browser.library.load([Conversation].self, from: "sessions/threads.json")
    try check(stored?.first(where: { $0.id == conversation.id })?.messages.last?.images == ["chat-images/synthetic.png"]
      && stored?.first(where: { $0.id == conversation.id })?.messages.last?.activities?.count == 1,
      "\(driver): combined image/action content persists")
    // Reopen an older development import while its file is unchanged: first attach must read.
    conversation.messages = [AgentMessage(role: "you", text: "Inspect")]
    conversation.link = nil
    conversation.scope = "native-v1|old-import"
    agent.restore(conversation)
    try check(await until { agent.messages.last?.text == "Done" && agent.messages.last?.activities?.count == 1 },
      "\(driver): an old input-only import migrates and refreshes on first attach")
    agent.clear()
  }
  let legacy = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"id":"old","role":"assistant","text":"Hello"}"#.utf8))
  try check(legacy.images == nil && legacy.activities == nil, "Old messages decode without images or actions")
  let pictured = AgentMessage(role: "assistant", text: "Done", images: ["chat-images/steered.png"])
  agent.messages = [AgentMessage(role: "you", text: "First"), AgentMessage(role: "you", text: "Also test"), pictured]
  let action = TranscriptActivity(id: "first-call", tool: "read", label: "Read files")
  agent.showLinked(LinkedHistory(messages: [
    .init(role: "you", text: "First"), .init(role: "assistant", text: "", activities: [action]),
    .init(role: "you", text: "Also test"), .init(role: "assistant", text: "Done"),
  ], working: false, path: nil, cwd: nil, model: nil, effort: nil))
  try check(agent.messages.last?.id == pictured.id && agent.messages.last?.images == pictured.images
    && agent.messages[1].images == nil, "Discovering earlier actions keeps a screenshot on its own steered turn")
  agent.showLinked(LinkedHistory(messages: [
    .init(role: "you", text: "First"), .init(role: "assistant", text: "", activities: [action]),
    .init(role: "you", text: "Also test"), .init(role: "assistant", text: "Done"), .init(role: "assistant", text: "Follow-up"),
  ], working: false, path: nil, cwd: nil, model: nil, effort: nil))
  try check(Set(agent.messages.map(\.id)).count == agent.messages.count
    && agent.messages.flatMap { $0.images ?? [] } == pictured.images!,
    "Multiple answer blocks keep unique identities and carry each screenshot once")
  agent.messages = [AgentMessage(role: "you", text: "Own setup", own: true)]
  agent.showLinked(LinkedHistory(messages: [
    .init(role: "you", text: "Own setup"), .init(role: "assistant", text: "", activities: [action]),
  ], working: false, path: nil, cwd: nil, model: nil, effort: nil))
  agent.showLinked(LinkedHistory(messages: [
    .init(role: "you", text: "Own setup"), .init(role: "assistant", text: "Connector result", activities: [action]),
  ], working: false, path: nil, cwd: nil, model: nil, effort: nil))
  try check(agent.messages.allSatisfy { $0.own == true }
    && AgentModel.sameSide(agent.messages, own: false).isEmpty,
    "Inserted actions and refreshed answers preserve own-setup history isolation")
  var spec = RunSpec(threadID: "own-actions", provider: .claude, executable: "/bin/true",
    model: "", effort: "low", mode: .answer, projectID: nil, projectName: nil,
    title: "Synthetic own-setup action", scope: "synthetic", autoRouting: false, grants: RunGrants(),
    limits: RunLimits(hard: 60, idle: 60))
  spec.grants.ownSetup = true
  let run = AgentRun(spec: spec, taskID: "synthetic", transcript: [AgentMessage(role: "you", text: "Own setup", own: true)])
  run.track(RunActivity(tool: "read", now: "Reading files", done: "Read files"), id: "own-call")
  run.append("Connector result")
  try check(run.transcript.last?.own == true && AgentModel.sameSide(run.transcript, own: false).isEmpty,
    "A live action-only row keeps subsequent text on the own-setup side")

  // Use the actual browser-failure callback, completion and selected-thread persistence.
  // No process is launched; Relay's notification exemption keeps this fixture silent even
  // when the checks run from a packaged app.
  func endingRun(_ title: String) -> AgentRun {
    agent.clear()
    var endingSpec = spec
    endingSpec.threadID = agent.conversationID
    endingSpec.title = title
    endingSpec.relay = true
    let ending = AgentRun(spec: endingSpec, taskID: "synthetic-ending-" + UUID().uuidString,
      transcript: [AgentMessage(role: "you", text: title, own: true)])
    agent.hub.adoptPreview(ending)
    agent.messages = ending.transcript
    return ending
  }
  func persisted(_ ending: AgentRun) -> Bool {
    let threads = browser.library.load([Conversation].self, from: "sessions/threads.json")
    let selected = browser.library.load([AgentMessage].self, from: "sessions/conversation.json")
    return threads?.first(where: { $0.id == ending.spec.threadID })?.messages == ending.transcript
      && selected == ending.transcript
  }
  for stopped in [true, false] {
    let label = stopped ? "Stop after a declined browser step" : "Error after a failed browser step"
    let reason = stopped ? "You declined this action." : "The page changed before this action."
    let ending = endingRun(label)
    browser.onTaskStepFailed?(ending.taskID, reason)
    let reply = ending.transcript.last!
    agent.hub.onTranscript?(ending)
    if stopped {
      agent.hub.stop(ending)
    } else {
      agent.hub.complete(ending, code: 1, diagnostic: "Synthetic process failure")
    }
    try check(reply.role == "assistant" && reply.text.isEmpty && reply.own == true
      && reply.activities?.count == 1 && reply.activities?.first?.failed == true
      && reply.activities?.first?.label == "Not done: " + reason
      && ending.transcript.last == reply,
      "\(label) preserves the activity-only message and its identity")
    try check(agent.messages == ending.transcript
      && ending.record.outcome == (stopped ? .stopped : .stuck)
      && agent.status == (stopped ? "Stopped" : "Needs attention")
      && (stopped || agent.error == ending.error),
      "\(label) remains visible with its completed outcome")
    try check(persisted(ending), "\(label) persists the failed activity for reopening")
  }

  let picturedEnding = endingRun("Screenshot without answer text")
  picturedEnding.addPicture("chat-images/synthetic-finished.png")
  let pictureReply = picturedEnding.transcript.last!
  agent.hub.stop(picturedEnding)
  try check(picturedEnding.transcript.last == pictureReply && pictureReply.images?.count == 1
    && agent.messages == picturedEnding.transcript && persisted(picturedEnding),
    "Stop preserves a screenshot-only reply in the visible and saved conversation")

  for emptyCollections in [false, true] {
    let blank = endingRun("Empty streaming placeholder")
    let input = blank.transcript
    blank.transcript.append(AgentMessage(role: "assistant", text: "",
      images: emptyCollections ? [] : nil, activities: emptyCollections ? [] : nil))
    agent.hub.stop(blank)
    try check(blank.transcript == input && agent.messages == input && persisted(blank),
      "Stop removes a truly blank placeholder with \(emptyCollections ? "empty" : "absent") content collections")
  }

  let summarized = endingRun("Finish summary after a declined step")
  browser.onTaskStepFailed?(summarized.taskID, "You declined this action.")
  summarized.addPicture("chat-images/synthetic-summary.png")
  var summaryReply = summarized.transcript.last!
  summaryReply.text = "The action was not performed."
  summarized.reportedSummary = summaryReply.text
  summarized.reportedOutcome = .done // Do not invoke a provider-backed outcome classifier.
  agent.hub.endAtFinish(summarized)
  try check(summarized.record.outcome == .done && summarized.transcript.last == summaryReply
    && summaryReply.activities?.first?.failed == true && summaryReply.images?.count == 1,
    "A finish summary preserves existing failed activity, screenshots, identity and own-setup scope")
  try check(agent.messages == summarized.transcript && persisted(summarized),
    "A finish summary publishes and saves the reply with all of its existing content")

  // Attention belongs to the run record, including when no assistant reply exists.
  // Capture exactly what the production end callback sees, before it saves the conversation.
  let previousEnd = agent.hub.onEnd
  var endedRecords: [String: RunRecord] = [:]
  agent.hub.onEnd = { ending in
    endedRecords[ending.id] = ending.record
    previousEnd?(ending)
  }
  defer { agent.hub.onEnd = previousEnd }
  func savedRun(_ ending: AgentRun) -> RunRecord? {
    browser.library.runs().first { $0.id == ending.id }
  }
  let failure = endingRun("Provider failure without an answer")
  failure.transcript.insert(contentsOf: [AgentMessage(role: "you", text: "Previous request"),
    AgentMessage(role: "assistant", text: "This old answer must never explain a new failure.")], at: 0)
  let unanswered = failure.transcript
  let reason = "The provider refused this request.\n" + String(repeating: "Review the selected model and account. ", count: 12)
  failure.error = "  \n" + reason + "\n  "
  agent.hub.complete(failure, code: 1, diagnostic: "")
  try check(failure.record.outcome == .stuck && failure.attentionDetail == reason.trimmingCharacters(in: .whitespacesAndNewlines)
    && failure.transcript == unanswered && persisted(failure),
    "Failure without a reply preserves the full reason without fabricating an assistant message")
  try check(endedRecords[failure.id]?.attentionDetail == failure.attentionDetail
    && endedRecords[failure.id]?.summary == String(failure.attentionDetail!.prefix(280))
    && savedRun(failure)?.attentionDetail == failure.attentionDetail,
    "Full failure detail and its short preview are durable before the end callback")
  let roundTrip = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(failure.record))
  try check(roundTrip == failure.record && roundTrip.attentionDetail == failure.attentionDetail,
    "RunRecord round-trip preserves the full attention detail")

  let reportedFailure = endingRun("Agent-reported failure")
  let reportedInput = reportedFailure.transcript
  reportedFailure.reportedOutcome = .stuck
  reportedFailure.reportedSummary = "The source document is unavailable. Provide a readable copy."
  agent.hub.complete(reportedFailure, code: 0, diagnostic: "")
  try check(reportedFailure.error == nil && reportedFailure.attentionDetail == reportedFailure.reportedSummary
    && endedRecords[reportedFailure.id]?.attentionDetail == reportedFailure.reportedSummary
    && savedRun(reportedFailure)?.attentionDetail == reportedFailure.reportedSummary
    && reportedFailure.transcript == reportedInput,
    "An agent-reported failure is available before completion even without a process error")

  let question = endingRun("Input request from a turn summary")
  question.reportedOutcome = .waiting
  question.reportedSummary = "A destination is needed."
  question.summary = try JSONDecoder().decode(TurnSummary.self,
    from: Data(#"{"kind":"answer","question":"Which folder should receive the report?","choices":["Downloads","Project"]}"#.utf8))
  agent.hub.complete(question, code: 0, diagnostic: "")
  try check(question.attentionDetail == question.summary?.question
    && endedRecords[question.id]?.attentionDetail == question.summary?.question
    && savedRun(question)?.attentionDetail == question.summary?.question,
    "A needs-user turn preserves its specific question before completion")

  let approval = endingRun("Approval needed after a reported completion")
  approval.reportedOutcome = .done
  approval.reportedSummary = "Finished preparing the edit."
  approval.approvals = [PendingApproval(id: "synthetic-approval", tool: "Edit", target: "Report.txt")]
  agent.hub.complete(approval, code: 0, diagnostic: "")
  let approvalDetail = ApprovalEvents.summary(approval.approvals.count)
  try check(approval.record.outcome == .waiting && approval.attentionDetail == approvalDetail
    && endedRecords[approval.id]?.attentionDetail == approvalDetail
    && savedRun(approval)?.attentionDetail == approvalDetail,
    "A pending approval takes precedence over a reported completion summary")

  for outcome in [RunRecord.Outcome.stuck, .waiting] {
    let blank = endingRun("Blank attention sources")
    blank.transcript.insert(contentsOf: [AgentMessage(role: "you", text: "Earlier request"),
      AgentMessage(role: "assistant", text: "Unrelated previous answer")], at: 0)
    let input = blank.transcript
    blank.reportedOutcome = outcome
    blank.reportedSummary = "  \n "
    blank.record.summary = "\t "
    blank.record.attentionDetail = " \n "
    agent.hub.complete(blank, code: 0, diagnostic: "")
    let fallback = RunAttention.detail(outcome: outcome)
    try check(blank.attentionDetail == fallback && savedRun(blank)?.attentionDetail == fallback
      && blank.transcript == input && blank.currentTurnResponse == nil,
      "\(outcome.rawValue): blank sources use a truthful fallback, never an earlier reply")
  }

  let unexplained = endingRun("Failure after a progress message")
  unexplained.transcript.append(AgentMessage(role: "assistant", text: "I am checking the files.", own: true))
  unexplained.reportedOutcome = .stuck
  agent.hub.complete(unexplained, code: 0, diagnostic: "")
  try check(unexplained.attentionDetail == RunAttention.detail(outcome: .stuck),
    "A progress sentence is not fabricated into the cause of a failure")

  let replyQuestion = endingRun("Input request in the current reply")
  replyQuestion.transcript.append(AgentMessage(role: "assistant", text: "Which date should I use?", own: true))
  replyQuestion.reportedOutcome = .waiting
  agent.hub.complete(replyQuestion, code: 0, diagnostic: "")
  try check(replyQuestion.attentionDetail == "Which date should I use?"
    && savedRun(replyQuestion)?.attentionDetail == replyQuestion.attentionDetail,
    "A needs-user run can preserve its current reply as the input request")

  SereinTray.shared.attach(hub: agent.hub, browser: browser)
  let dismissed = endingRun("Dismissed before its outcome classification")
  dismissed.reportedOutcome = .done
  agent.hub.complete(dismissed, code: 0, diagnostic: "")
  agent.hub.dismiss(dismissed)
  dismissed.record.outcome = .waiting
  dismissed.summary = try JSONDecoder().decode(TurnSummary.self,
    from: Data(#"{"kind":"answer","question":"Which destination should I use?","choices":[]}"#.utf8))
  dismissed.record.attentionDetail = dismissed.attentionDetail
  dismissed.record.summary = dismissed.attentionDetail
  // The classifier logs the ended run, even when it is no longer in hub.runs.
  try browser.library.appendRun(dismissed.record)
  agent.hub.onRecord?(dismissed.record)
  agent.hub.onSummary?(dismissed)
  try check(agent.hub.latest(for: dismissed.spec.threadID) == nil
    && SereinTray.shared.record(dismissed.spec.threadID)?.attentionDetail == dismissed.attentionDetail
    && agent.outcomeSummary?.question == dismissed.summary?.question,
    "A dismissed run's late question reaches its saved card and open chat without relaunching")

  let oldQuestion = endingRun("Older question finishing late")
  oldQuestion.reportedOutcome = .done
  agent.hub.complete(oldQuestion, code: 0, diagnostic: "")
  oldQuestion.summary = try JSONDecoder().decode(TurnSummary.self,
    from: Data(#"{"kind":"answer","question":"An outdated question?","choices":[]}"#.utf8))
  let nextTurn = AgentRun(spec: oldQuestion.spec, taskID: "synthetic-next-turn-" + UUID().uuidString,
    transcript: oldQuestion.transcript + [AgentMessage(role: "you", text: "A new request", own: true)])
  agent.hub.adoptPreview(nextTurn)
  agent.outcomeSummary = nil
  agent.hub.onSummary?(oldQuestion)
  try check(agent.outcomeSummary == nil,
    "A delayed classifier for an older run cannot hide the next turn's attention notice")
  nextTurn.error = "The current request lost its connection."
  agent.hub.complete(nextTurn, code: 0, diagnostic: "")
  agent.hub.onSummary?(oldQuestion)
  try check(agent.outcomeSummary == nil && agent.error == nextTurn.error,
    "The latest failure stays visible when an older input classification arrives")
  nextTurn.summary = try JSONDecoder().decode(TurnSummary.self,
    from: Data(#"{"kind":"failed","question":"The current request lost its connection.","choices":[]}"#.utf8))
  agent.hub.onSummary?(nextTurn)
  try check(agent.outcomeSummary?.question == nextTurn.summary?.question,
    "The current run's own outcome summary still reaches its selected chat")

  let startup = AgentRun(spec: spec, taskID: "synthetic-startup-" + UUID().uuidString,
    transcript: [AgentMessage(role: "you", text: "Start this task", own: true)])
  let startupReason = "The task was not started because agent history could not be saved."
  browser.abandonPreparedStart(startup, outcome: .stuck, message: startupReason)
  try check(!startup.engineFailed && startup.attentionDetail == startupReason
    && startup.record.summary == startupReason && savedRun(startup)?.attentionDetail == startupReason
    && startup.transcript.count == 1,
    "An abandoned prepared start retains its failure detail without an assistant reply")
}
#endif
