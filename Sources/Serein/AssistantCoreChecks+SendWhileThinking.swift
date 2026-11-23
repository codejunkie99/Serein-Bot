#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  static func sendWhileThinking(_ check: Check) throws {
    try check(
      ComposerKey.resolve(running: true, hasText: true, shift: false, option: false) == .addToStep
        && ComposerKey.resolve(running: true, hasText: true, shift: false, option: true) == .interruptAndSend
        && ComposerKey.resolve(running: false, hasText: true, shift: false, option: false) == .send,
      "Return while a step runs adds the words to it, and Option-Return still stops and sends")

    func path(_ wire: HarnessDriver.Wire?, context: Bool = false, waiting: Bool = false, person: Bool = true)
      -> RunSteering.Path
    { RunSteering.path(wire, carriesContext: context, othersWaiting: waiting, byPerson: person) }
    let into: Set<HarnessDriver> = [.claude, .codex, .pi, .ohMyPi]
    for driver in HarnessDriver.allCases {
      try check(path(driver.wire) == (into.contains(driver) ? .intoTurn : .nextTurn),
        "\(driver.displayName) takes words sent mid-turn \(into.contains(driver) ? "into the turn" : "with the next turn")")
    }
    try check(path(nil) == .intoTurn, "The Local model takes words sent mid-turn into the turn")
    for wire: HarnessDriver.Wire? in [nil, .claudeStream, .codexAppServer, .acp, .piJSON] {
      try check(
        path(wire, context: true) == .nextTurn && path(wire, waiting: true) == .nextTurn
          && path(wire, person: false) == .nextTurn,
        "\(wire?.rawValue ?? "local"): chips, words behind waiting words, and automation go with the next turn")
    }

    let line = SteerLedger.Line(shown: "End with BANANA. sk-secret", wire: "End with BANANA.")
    var ledger = SteerLedger()
    let other = SteerLedger.Line(shown: "second", wire: "second")
    ledger.wrote(line)
    ledger.wrote(other)
    try check(ledger.take() == line && ledger.take() == other && ledger.take() == nil,
      "An engine Serein drives takes lines oldest first")
    ledger.wrote(line)
    ledger.wrote(other)
    try check(
      ledger.leftovers() == [line.shown, "second"] && ledger.waiting.isEmpty && ledger.leftovers().isEmpty,
      "Unread words leave the ledger once, as the person typed them, oldest first")

    var queue = MessageQueue()
    let ids = ["a", "b", "c", "d"].compactMap { queue.enqueue($0, thread: "T")?.id }
    queue.enqueue("x", thread: "U")
    let burst = queue.popBurst(for: "T") { $0.id == ids[2] }
    try check(
      burst.map(\.text) == ["a", "b", "c"] && queue.items(for: "T").map(\.text) == ["d"]
        && queue.items(for: "U").map(\.text) == ["x"],
      "Waiting messages go as one turn, through the first that carries chips, and other threads keep theirs")
    queue.removeAll(thread: "T")
    for index in 0..<MessageQueue.maxPerThread { queue.enqueue("m\(index)", thread: "T") }
    queue.requeue(["r1", "r2"], thread: "T")
    try check(
      queue.items(for: "T").prefix(3).map(\.text) == ["r1", "r2", "m0"]
        && queue.items(for: "T").count == MessageQueue.maxPerThread + 2 && queue.items(for: "U").count == 1,
      "Words an engine never read go back ahead of the waiting ones, past the cap")

    let folded = RelaySteering.prompt(["a", "b"], tags: false)
    try check(
      folded.contains("[1] a\n[2] b") && !folded.contains("[reply") && RelaySteering.prompt([" a "], tags: false) == "a"
        && RelaySteering.prompt(["a", "b"]).contains("[reply 2]"),
      "A folded turn in a task chat numbers the messages and asks for no reply tags")

    let steer = CodexParams.steer(thread: "t", turn: "u", text: "x")
    try check(
      steer["threadId"] as? String == "t" && steer["expectedTurnId"] as? String == "u"
        && steer["input"] as? [[String: String]] == [["type": "text", "text": "x"]],
      "A Codex steer names the turn it expects to still be running")

    for hint in [RunSteering.hint(.intoTurn, app: "Claude Code"), RunSteering.hint(.nextTurn, app: "Cursor Agent")] {
      try check(
        hint.count < 60 && !hint.contains("Queue") && !hint.contains("Stop") && !hint.contains("\u{2014}"),
        "The composer's line is short and offers no Queue or Stop: \(hint)")
    }
    try MainActor.assumeIsolated { try steeredRun(check) }
  }

  @MainActor private static func steeredRun(_ check: Check) throws {
    let spec = RunSpec(threadID: "steer-check", provider: .claude, executable: "/usr/bin/false",
      model: "", effort: "low", mode: .answer, projectID: nil, projectName: nil,
      title: "Check", scope: "", autoRouting: false, grants: RunGrants(), limits: RunLimits(hard: 2, idle: 2))
    let run = AgentRun(spec: spec, taskID: "steer-check", transcript: [
      AgentMessage(role: "you", text: "first"), AgentMessage(role: "assistant", text: "Working"),
    ])
    run.took("mid", ownReply: false)
    try check(
      run.transcript.map(\.text) == ["first", "mid", "Working"],
      "Words read mid-answer sit above the reply that streams, which stays last")
    run.took("after", ownReply: true)
    try check(
      run.transcript.map(\.text) == ["first", "mid", "Working", "after", ""] && run.transcript.last?.role == "assistant",
      "Words answered after the reply get a bubble below it and a new reply")

    // A run with no open wire takes nothing: the words go straight back for the next turn.
    let hub = AgentHub(observesLifecycle: false)
    var back: [String] = []
    hub.steer(run, "later") { back += $0 }
    try check(
      !hub.takesWords(run) && back == ["later"] && run.steering.waiting.isEmpty,
      "A turn whose engine cannot read words now hands them back for the next turn")
  }
}
#endif
