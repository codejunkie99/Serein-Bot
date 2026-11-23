import AppKit
import Combine
import SereinCore
import SwiftUI

#if DEBUG
@MainActor func checkTranscriptUpdates() async throws {
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("Transcript updates: " + label) }
    print("PASS: " + label)
  }
  let updates = TranscriptUpdates(interval: 20_000_000)
  var delivered: [Int] = []
  for i in 0..<1000 { updates.submit { delivered.append(i) } }
  try check(delivered == [0], "a stream burst presents its first update immediately")
  try await Task.sleep(nanoseconds: 80_000_000)
  try check(delivered == [0, 999], "the trailing update coalesces all remaining deltas")
  updates.submit { delivered.append(1000) }
  updates.submit { delivered.append(1001) }
  updates.flush()
  try check(delivered.last == 1001, "saving and completion flush the latest update immediately")
  updates.submit { delivered.append(1002) }
  updates.cancel()
  try await Task.sleep(nanoseconds: 60_000_000)
  try check(delivered.last == 1001, "cancelled presentation never overwrites a different thread")

  let root = FileManager.default.temporaryDirectory.appendingPathComponent("serein-transcript-" + UUID().uuidString)
  let browser = try BrowserModel(root: root)
  let agent = AgentModel(browser: browser, discoverProviders: false)
  defer {
    browser.shutdown()
    try? FileManager.default.removeItem(at: root)
  }
  let spec = RunSpec(threadID: agent.conversationID, provider: .codex, executable: "/bin/false",
    model: "synthetic", effort: "low", mode: .answer, projectID: nil, projectName: nil,
    title: "Synthetic stream", scope: "", autoRouting: false, grants: RunGrants(),
    limits: RunLimits(hard: 120, idle: 120))
  let run = AgentRun(spec: spec, taskID: "synthetic", transcript: [AgentMessage(role: "assistant", text: "")])
  agent.hub.adoptPreview(run)
  agent.messages = run.transcript
  agent.status = run.phase
  let note = NSHostingView(rootView: ThreadSessionNote(agent: agent)
    .environment(\.palette, Palette.dusk).frame(width: 640))
  let smallNote = note.fittingSize.height
  run.contextTokens = ThreadSessionNote.threshold + 1000
  try await Task.sleep(nanoseconds: 40_000_000)
  note.layoutSubtreeIfNeeded()
  try check(note.fittingSize.height > smallNote,
    "token-only metadata immediately updates the native large-session warning")
  run.contextTokens = nil
  var publications = 0
  let watch = agent.objectWillChange.sink { publications += 1 }
  defer { watch.cancel() }
  for _ in 0..<1000 { agent.hub.onTranscript?(run) }
  try await Task.sleep(nanoseconds: 60_000_000)
  try check(publications == 0, "1,000 unchanged provider events cause no selected-thread publications")
  let started = DispatchTime.now().uptimeNanoseconds
  for _ in 0..<1000 {
    run.append("x")
    agent.hub.onTranscript?(run)
  }
  try await Task.sleep(nanoseconds: 100_000_000)
  try check(agent.messages.last?.text == String(repeating: "x", count: 1000),
    "coalescing preserves every transcript delta")
  try check(publications <= 3, "a 1,000-delta burst needs at most three transcript publications")
  let streamPublications = publications
  run.append(" saved")
  agent.hub.onTranscript?(run)
  agent.saveConversation()
  try check(browser.library.load([AgentMessage].self, from: "sessions/conversation.json")?.last?.text == run.transcript.last?.text,
    "saving between frames retains the complete stream")
  run.append(" final")
  agent.hub.onTranscript?(run)
  agent.hub.stop(run)
  try check(agent.messages.last?.text == run.transcript.last?.text && agent.status == "Stopped",
    "Stop presents the final transcript and outcome without waiting for a display frame")
  let stopped = agent.messages
  try await Task.sleep(nanoseconds: 70_000_000)
  try check(agent.messages == stopped && agent.status == "Stopped", "a queued frame cannot revive a stopped run")
  let sourceThread = agent.conversationID
  let next = AgentRun(spec: spec, taskID: "synthetic-next",
    transcript: agent.messages + [AgentMessage(role: "assistant", text: "")])
  agent.hub.adoptPreview(next)
  next.append("first")
  agent.hub.onTranscript?(next)
  next.append(" and pending")
  agent.hub.onTranscript?(next)
  let other = Conversation(id: UUID().uuidString, title: "Other synthetic thread",
    messages: [AgentMessage(role: "you", text: "Other thread")], provider: .codex, mode: .answer,
    projectID: nil, remoteID: nil, scope: "", updatedAt: Date())
  agent.openConversation(other)
  try await Task.sleep(nanoseconds: 60_000_000)
  try check(agent.conversationID == other.id && agent.messages == other.messages,
    "switching threads cancels any pending display of the former thread")
  let savedThreads = browser.library.load([Conversation].self, from: "sessions/threads.json") ?? []
  try check(savedThreads.first { $0.id == sourceThread }?.messages.last?.text == next.transcript.last?.text,
    "switching threads saves deltas received between presentation frames")
  agent.openThread(sourceThread)
  try check(agent.messages == next.transcript, "returning to a running thread presents its latest transcript immediately")
  agent.hub.stop(next)
  let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
  print(String(format: "BENCH: 1,000 streamed deltas, %d transcript publications, %.2f ms including async waits", streamPublications, milliseconds))
  for source in ["", "plain text", String(repeating: "汉字🙂e\u{301} ", count: 5000),
    String(repeating: "汉", count: 40_000), String(repeating: "🙂", count: 99_999),
    String(repeating: "e\u{301}", count: 100_000), String(repeating: "x", count: 100_001)] {
    for delta in ["x", "\u{301}", "🙂"] {
      let bounded = AgentRun(spec: spec, taskID: "synthetic-character-bound",
        transcript: [AgentMessage(role: "assistant", text: source)])
      let expected = source.count < 100_000 ? source + delta : source
      bounded.append(delta)
      try check(bounded.transcript.last?.text == expected,
        "stream byte-count fast path preserves the original grapheme limit and append semantics")
      bounded.thinking = source
      var expectedThought = source + delta
      if expectedThought.count > 100_000 { expectedThought = String(expectedThought.suffix(80_000)) }
      bounded.think(delta)
      try check(bounded.thinking == expectedThought,
        "reasoning byte-count fast path preserves Unicode and the original suffix boundary")
    }
  }
}
#endif
