#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// `--verify-relay-live`: Relay on the user's real Claude Code (consumes their usage), in a
  /// throwaway library. A note through `remember`, then a real delegated run through agent_start
  /// and agent_wait. Touches no Mac app and no website.
  @MainActor static func relayLive(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 250_000_000) }
    }
    // SEREIN_LIVE_PROVIDER=<provider> runs the same turns with that harness as Relay's brain
    // (codex, opencode, grok, …); Claude Code when unset or unknown.
    let requested = ProcessInfo.processInfo.environment["SEREIN_LIVE_PROVIDER"] ?? ""
    let provider = Provider.allCases.first { $0.rawValue == requested || $0.name == requested } ?? .claude
    try await waitFor(90) { agent.available[provider] != nil && HarnessRegistry.shared.snapshot(provider)?.checkedAt != nil }
    try check(agent.available[provider] != nil, "\(provider.name) is found and checked on this Mac")
    guard let relay = RelayOrchestrator.shared else { throw SereinError.invalid("FAIL: Relay did not start") }
    RelayOrchestrator.enabledOverride = true
    relay.provider = provider
    var approvals: [String] = []
    relay.confirmOverride = { title, _ in
      approvals.append(title)
      return true
    }
    defer {
      relay.confirmOverride = nil
      RelayOrchestrator.enabledOverride = nil
    }
    func turn(_ text: String, within seconds: Double) async throws -> (reply: String, seconds: Int) {
      let started = Date()
      relay.ask(text)
      try await waitFor(20) { relay.working }
      try await waitFor(seconds) { !relay.working }
      let reply = relay.transcript.last(where: { $0.role == "assistant" })?.text ?? ""
      if let error = relay.lastError ?? agent.hub.latest(for: relay.threadID)?.error {
        results.append("NOTE: \(error.prefix(300))")
      }
      return (reply, Int(Date().timeIntervalSince(started)))
    }

    let first = try await turn("Remember that my favorite color is green. Then reply with the single word NOTED.", within: 240)
    results.append("INFO: first turn \(first.seconds) s: \(first.reply.prefix(120))")
    try check(relay.notes.contains { $0.text.lowercased().contains("green") }, "Relay saved the note through its remember tool")
    try check(first.reply.uppercased().contains("NOTED"), "Relay answered in its Main chat")

    let second = try await turn(
      "Use agent_start with destination answer to ask another agent: \"What is 17 times 3? Reply with only the number.\" Then use agent_wait until it finishes, and tell me the number it gave.",
      within: 420)
    results.append("INFO: second turn \(second.seconds) s: \(second.reply.prefix(160))")
    let child = relay.state.children.last
    try check(child != nil, "Relay delegated a real run")
    let childReply = child.flatMap { c in agent.conversations.first { $0.id == c.threadID } }?.messages
      .last(where: { $0.role == "assistant" })?.text ?? ""
    results.append("INFO: delegated run answered: \(childReply.prefix(80))")
    try check(childReply.contains("51"), "The delegated run answered on its own thread")
    try check(second.reply.contains("51"), "Relay waited for it and reported the answer")
    try check(relay.activity.contains { $0.text.hasPrefix("Asked \(provider.name)") }, "“What I did” recorded the delegation")
    results.append("INFO: approvals asked: \(approvals)")

    // Relay speaks first: a real daily brief. Mac steps are declined here (reading Calendar would
    // open a macOS permission dialog with nobody to answer it).
    relay.confirmOverride = { title, _ in
      approvals.append(title)
      return !(title.hasPrefix("Serein wants to") || title.contains("Mac"))
    }
    // Check-ins ship Never for new installs; this part tests them at Often.
    relay.proactiveOverride = .jarvis
    defer { relay.proactiveOverride = nil }
    RelayOrchestrator.quietForChecks = false
    var nine = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    nine.hour = 9
    let started = Date()
    relay.speakFirst(now: Calendar.current.date(from: nine)!, idle: 5)
    RelayOrchestrator.quietForChecks = true
    try await waitFor(20) { relay.working }
    try await waitFor(240) { !relay.working }
    let brief = relay.transcript.last(where: { $0.role == "assistant" })?.text ?? ""
    results.append("INFO: daily brief \(Int(Date().timeIntervalSince(started))) s: \(brief.prefix(200))")
    try check(!brief.isEmpty && brief != RelayProactive.nothing && relay.proactiveMemory.briefDay == RelayProactive.dayKey(Date()),
              "Relay gave a real daily brief on its own")
    try check(agent.hub.latest(for: relay.threadID)?.spec.title == "Serein · Daily brief", "The brief's run has a readable title")

    // A real plugin through Relay: the bundled notes example, under Only risky steps. Its write still
    // asks first, as PluginChecks expects; the override above answers the card.
    let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../examples/plugins/notes-demo").standardizedFileURL
    let plugin = try PluginHost.shared.install(from: example)
    try await PluginHost.shared.enable(plugin)
    relay.autopilotOverride = true
    defer { relay.autopilotOverride = nil }
    let third = try await turn("With the Notes demo plugin, add the note \"buy oat milk\", then list my notes and tell me what they are.", within: 300)
    results.append("INFO: plugin turn \(third.seconds) s: \(third.reply.prefix(160))")
    let data = browser.library.root.appendingPathComponent("plugin-data/dev.serein.notes-demo/notes.json")
    try check((try? String(contentsOf: data, encoding: .utf8))?.contains("buy oat milk") == true, "Relay used a plugin tool for real")
    try check(third.reply.lowercased().contains("oat milk"), "Relay reported the plugin's answer")
    try check(approvals.contains("Allow “Notes demo” to “add note”?")
                && relay.activity.contains { $0.text.hasPrefix("Notes demo:") && $0.how == .allowed },
              "The plugin write asked first under Only risky steps, then ran")
    return results
  }
}
#endif
