#if DEBUG
import AppKit
import SereinCore

/// An assistant at its AI app's usage limit continues on a backup by itself and goes back at the
/// reset (RelayLimitFailover.swift): the rules, then a real Relay on a throwaway library with two
/// AI apps pinned at paths with nothing there, so no turn ever starts.
extension AssistantCoreChecks {
  static func failover(_ check: Check) throws {
    try failoverRules(check)
    try MainActor.assumeIsolated { try failoverWiring(check) }
  }

  private static func failoverRules(_ check: Check) throws {
    func route(_ provider: String, _ model: String = "", _ cost: ModelRoute.CostClass = .yourPlan, reason: String? = nil) -> ModelRoute {
      ModelRoute(provider: provider, model: model, costClass: cost, caps: [], installed: true, reason: reason)
    }
    let claude = route("claude")
    try check(LimitFailover.allowed(from: claude, to: route("codex")),
      "failover: another AI app on the person's plan takes over with nobody asked")
    try check(!LimitFailover.allowed(from: claude, to: route("claude", "opus")),
      "failover: never another model or sign-in of the same AI app, so never a second account on the same subscription")
    try check(!LimitFailover.allowed(from: claude, to: route("codex", "", .yourKey)),
      "failover: a route billed on the person's key keeps its pay card")
    try check(!LimitFailover.allowed(from: claude, to: route("codex", reason: "Not signed in to the Codex CLI")),
      "failover: an AI app that is not signed in is never moved to")

    let gb = Locale(identifier: "en_GB")
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(2 * 3600)
    try check(
      LimitFailover.line(hit: "Claude Code", continued: "Codex", back: "Claude Code", resetsAt: reset, now: now, calendar: utc, locale: gb)
        == "Claude Code hit its usage limit, so Codex continued. Back to Claude Code after 10:00.",
      "failover: the run's one line names both AI apps and the reset")

    let a = AssistantRoute(provider: "claude", model: "")
    let b = AssistantRoute(provider: "codex", model: "")
    let c = AssistantRoute(provider: "gemini", model: "")
    var moves = LimitFailovers()
    moves.record(.init(profileID: "p", from: a, to: b, resetsAt: reset, at: now))
    let none: (String) -> Date? = { _ in nil }
    try check(moves.due("p", current: b, limitedUntil: none, now: reset.addingTimeInterval(-60)) == .wait,
      "failover: before the reset it stays on the backup")
    try check(moves.due("p", current: b, limitedUntil: { $0 == "claude" ? reset.addingTimeInterval(600) : nil }, now: reset) == .wait,
      "failover: a limit met again meanwhile keeps it there")
    try check(moves.due("p", current: c, limitedUntil: none, now: reset) == .moved,
      "failover: moved by hand since, it does not go back by itself")
    moves.record(.init(profileID: "p", from: b, to: c, resetsAt: nil, at: now.addingTimeInterval(60)))
    try check(moves.due("p", current: c, limitedUntil: none, now: reset) == .back(.init(profileID: "p", from: a, to: c, resetsAt: reset, at: now)),
      "failover: a backup that hits its own limit moves on, and it still goes back to the AI app it started on")
    var unnamed = LimitFailovers()
    unnamed.record(.init(profileID: "p", from: a, to: b, resetsAt: now, at: now))
    try check(unnamed.due("p", current: b, limitedUntil: none, now: now.addingTimeInterval(LimitFailover.unknownResetWait - 1)) == .wait,
      "failover: with no reset named it tries its own AI app again no sooner than an hour")
  }

  @MainActor private static func failoverWiring(_ check: Check) throws {
    guard RelayOrchestrator.shared == nil else {
      try check(false, "failover wiring: no Relay runs before this suite starts one")
      return
    }
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("serein-failover-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let browser = try BrowserModel(root: root)
    try files.createDirectory(at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
    let agent = AgentModel(browser: browser, discoverProviders: false)
    let relay = RelayOrchestrator.start(agent: agent, browser: browser)
    defer { RelayOrchestrator.releaseForChecks(relay) }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    let id = relay.team.activeID
    // A chat that is not on screen: a move never sends the hold, so no turn starts here.
    let chat = "failover-chat"
    func hold() -> String {
      let item = HeldMessage(text: "Finish the summary", at: Date(), reason: .usageLimit, threadID: chat)
      relay.holdForChecks(.init(message: item))
      return item.id
    }
    func provider() -> String? { relay.team.profiles.first { $0.id == id }?.route?.provider }
    func said(_ prefix: String) -> Bool {
      let thread = relay.threadID
      let messages = thread == agent.conversationID ? agent.messages : agent.conversations.first { $0.id == thread }?.messages ?? []
      return messages.contains { $0.notice == true && $0.text.hasPrefix(prefix) }
    }

    agent.pin(.claude, executable: root.appendingPathComponent("claude").path)
    let claude = Provider.claude.rawValue
    let codex = Provider.codex.rawValue
    _ = relay.setProfileRoute(id, AssistantRoute(provider: claude, model: ""))
    let reset = Date().addingTimeInterval(2 * 3600)
    relay.limitForChecks(.claude, until: reset)

    let alone = hold()
    relay.continueElsewhere(alone)
    settle()
    try check(provider() == claude && relay.held.contains { $0.id == alone } && relay.limitFailovers.rows.isEmpty,
      "failover wiring: with no other AI app ready, the message keeps its hold and the assistant stays")
    try check(!said("Claude Code hit its usage limit"), "failover wiring: with nothing moved, the run says nothing moved")

    // The only other AI app is at its own limit: nothing else is left but Claude Code itself.
    agent.pin(.codex, executable: root.appendingPathComponent("codex").path)
    relay.limitForChecks(.codex, until: reset)
    relay.continueElsewhere(alone)
    settle()
    try check(provider() == claude && relay.limitFailovers.rows.isEmpty,
      "failover wiring: never another Claude Code model or account at Claude Code's limit")
    relay.limitForChecks(.codex, until: Date().addingTimeInterval(-1))

    let parked = AgentRun(
      spec: RunSpec(threadID: chat, provider: .claude, executable: "/usr/bin/false", model: "", effort: "low", mode: .anywhere,
        projectID: nil, projectName: nil, title: "Check", scope: "", autoRouting: false, grants: RunGrants(),
        limits: RunLimits(hard: 2, idle: 2), relay: true),
      taskID: "failover-check", transcript: [])
    parked.record.outcome = .waiting
    parked.reportedSummary = EngineTurn.parked
    relay.noteSecureCard(parked)
    relay.continueElsewhere(alone)
    settle()
    try check(provider() == claude && relay.limitFailovers.rows.isEmpty,
      "failover wiring: a chat holding a secure card never switches AI apps by itself")
    parked.record.outcome = .done
    parked.reportedSummary = nil
    relay.noteSecureCard(parked)

    let before = relay.team.profiles.first { $0.id == id }
    relay.continueElsewhere(alone)
    settle()
    try check(provider() == codex, "failover wiring: at Claude Code's limit, Codex continues with nobody asked")
    var after = relay.team.profiles.first { $0.id == id }
    after?.route = before?.route
    try check(after == before && relay.team.activeID == id,
      "failover wiring: the same assistant continues, with its access and folder as they were")
    try check(said("Claude Code hit its usage limit, so Codex continued. Back to Claude Code after "),
      "failover wiring: the run says which AI app continued and when it goes back")

    relay.restoreAfterLimit(id, now: reset.addingTimeInterval(-60))
    try check(provider() == codex, "failover wiring: before the reset, the next turn stays on Codex")
    relay.restoreAfterLimit(id, now: reset.addingTimeInterval(60))
    try check(provider() == claude && relay.limitFailovers.rows.isEmpty,
      "failover wiring: after the reset, the next turn is back on Claude Code")
    try check(said(LimitFailover.backLine(Provider.claude.name)), "failover wiring: the run says it went back")
  }
}
#endif
