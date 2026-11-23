import Foundation
import SereinCore

/// An assistant at its AI app's usage limit continues on a backup by itself through the same
/// path as Use another AI app… (`continueElsewhere`), and goes back at the start of its first
/// turn after the reset. The rules are pure, in SereinCore/LimitFailover.swift.
extension RelayOrchestrator {
  static let limitFailoversFile = "relay/limit-failovers.json"

  /// R20: a card waits on the person for `task`: a secure card or person step (keyed by task), or
  /// an approval in its chat. A chat with no task passes its thread id.
  func holdsCard(task: String) -> Bool {
    let thread = browser.threadID(forTask: task) ?? task
    return browser.secureCards.holdsCard(task: task) || cardThreads.contains(thread)
      || approvals.contains { $0.threadID == thread }
  }

  /// Return the held turn to resend only after the route changed and the same chat still owns it.
  func switchHeldRoute(_ id: String, step: ModelFallback.Step, assistant: String, byPerson: Bool) async -> Held? {
    // Route changes affect the assistant as well as the held chat. Recheck the actual hold
    // and both threads inside switchRoute, including after a paid-route confirmation waits.
    let current = {
      guard self.team.activeID == assistant, let item = self.held.first(where: { $0.id == id }) else { return false }
      guard !byPerson else { return true }
      return [item.message.threadID, self.knownMainThread(of: assistant)].compactMap { $0 }.allSatisfy { thread in
        !self.holdsCard(task: self.agent.hub.run(for: thread)?.taskID ?? thread)
      }
    }
    guard await switchRoute(step.route, for: assistant, isCurrent: current, byPerson: byPerson || !step.sameCost, atLimit: true),
      team.activeID == assistant, let item = held.first(where: { $0.id == id }),
      item.scheduled != nil || item.message.threadID == threadID else { return nil }
    return item
  }

  /// `switchRoute` is moving `id` off `from` at its usage limit: the move is kept until the reset,
  /// and the run says so.
  func failedOver(_ id: String, from: ModelRoute, to: ModelRoute, now: Date = Date()) {
    let reset = namedLimitResets[from.provider].flatMap { $0 > now ? $0 : nil }
    limitFailovers.record(.init(
      profileID: id, from: AssistantRoute(provider: from.provider, model: from.model),
      to: AssistantRoute(provider: to.provider, model: to.model), resetsAt: reset, at: now))
    guard let row = limitFailovers.rows.first(where: { $0.profileID == id }) else { return }
    let line = LimitFailover.line(
      hit: Provider(rawValue: from.provider).name, continued: Provider(rawValue: to.provider).name,
      back: Provider(rawValue: row.from.provider).name, resetsAt: row.resetsAt, now: now)
    note("\(profileName(id)) moved to \(ModelBackups.name(to)) at a usage limit", .auto)
    post(AgentMessage(role: "assistant", text: line, notice: true), into: mainThread(of: id))
  }

  /// Before an assistant's turn: back to the AI app it started on once that one's limit reset.
  func restoreAfterLimit(_ profileID: String, now: Date = Date()) {
    let current = team.profiles.first { $0.id == profileID }?.route
    switch limitFailovers.due(profileID, current: current, limitedUntil: { self.limitedApps[$0] }, now: now) {
    case .none, .wait:
      return
    case .moved:
      limitFailovers.forget(profileID)
    case .back(let row):
      let provider = Provider(rawValue: row.from.provider)
      let thread = knownMainThread(of: profileID)
      guard Self.assistantRouteRefusal(provider) == nil,
        agent.routes(provider, models: [row.from.model]).first?.selectable == true,
        !(thread.map { holdsCard(task: agent.hub.run(for: $0)?.taskID ?? $0) } ?? false), setProfileRoute(profileID, row.from)
      else { return }
      limitFailovers.forget(profileID)
      if let thread { agent.dropApprovals(chat: thread) }
      note("\(profileName(profileID)) is back on \(provider.name) after its usage limit", .auto)
      post(AgentMessage(role: "assistant", text: LimitFailover.backLine(provider.name), notice: true),
           into: thread ?? mainThread(of: profileID))
    }
  }

  /// A relay turn that parked on a secure card leaves its chat holding the card until a later
  /// turn there ends another way.
  func noteSecureCard(_ run: AgentRun) {
    guard run.spec.relay else { return }
    if run.record.outcome == .waiting, run.reportedSummary == EngineTurn.parked {
      cardThreads.insert(run.spec.threadID)
    } else {
      cardThreads.remove(run.spec.threadID)
    }
  }
}
