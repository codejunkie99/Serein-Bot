import Foundation
import SereinCore

extension RelayOrchestrator {
  func makeResearchCoordinator() -> ResearchCoordinator {
    ResearchCoordinator(file: browser.library.root.appendingPathComponent("relay/research.sqlite"),
      ready: { job in
        let provider = Provider(rawValue: job.provider)
        return HarnessRegistry.shared.snapshot(provider)?.checkedAt != nil
          && provider.driver.map { !HarnessRegistry.shared.refreshing.contains($0) } == true
      },
      authorize: { [weak self] job, source in
        guard let self else { return "Serein is not available." }
        return researchRefusal(job, source: source)
      }, extract: { [weak self] job, index in
        guard let self else { throw CancellationError() }
        if let reason = researchRefusal(job, source: job.sources[index]) { throw SereinError.invalid(reason) }
        let provider = Provider(rawValue: job.provider)
        guard let executable = agent.available[provider] else { throw SereinError.invalid("Connect the AI app used for this research.") }
        let reply = try await StructuredAgent().run(executable: executable, provider: provider, model: job.model,
                                                    prompt: job.extractionPrompt(index))
        return try StructuredOutput.decode(ResearchJob.Extraction.self, text: reply)
      }, compare: { [weak self] job, index in
        guard let self else { throw CancellationError() }
        if let reason = researchRefusal(job, source: nil) { throw SereinError.invalid(reason) }
        let provider = Provider(rawValue: job.provider)
        guard let executable = agent.available[provider] else { throw SereinError.invalid("Connect the AI app used for this research.") }
        let reply = try await StructuredAgent().run(executable: executable, provider: provider, model: job.model,
                                                    prompt: job.claimCheckPrompt(index))
        return try StructuredOutput.decode(ResearchClaimCheck.self, text: reply)
      }, plan: { [weak self] job in
        guard let self else { throw CancellationError() }
        if let reason = researchRefusal(job, source: nil) { throw SereinError.invalid(reason) }
        let provider = Provider(rawValue: job.provider)
        guard let executable = agent.available[provider] else { throw SereinError.invalid("Connect the AI app used for this research.") }
        let reply = try await StructuredAgent().run(executable: executable, provider: provider, model: job.model,
                                                    prompt: job.followUpPlanPrompt)
        return try StructuredOutput.decode(ResearchFollowUp.Plan.self, text: reply)
      }, select: { [weak self] job in
        guard let self else { throw CancellationError() }
        if let reason = researchRefusal(job, source: nil) { throw SereinError.invalid(reason) }
        let provider = Provider(rawValue: job.provider)
        guard let executable = agent.available[provider] else { throw SereinError.invalid("Connect the AI app used for this research.") }
        let reply = try await StructuredAgent().run(executable: executable, provider: provider, model: job.model,
                                                    prompt: job.followUpSelectionPrompt)
        return try StructuredOutput.decode(ResearchFollowUp.Selection.self, text: reply)
      }, deliver: { [weak self] job in self?.deliverResearch(job) == true })
  }

  /// Every boundary uses current settings, including after an await. The notebook contains no
  /// capability or sign-in grant. The original AI route is retained rather than silently replaced.
  func researchRefusal(_ job: ResearchJob, source: ResearchJob.Source?) -> String? {
    if state.paused { return "Serein is stopped. Resume Serein before continuing research." }
    guard let owner = team.profiles.first(where: { $0.id == job.owner }), !owner.isPaused else {
      return "The assistant that started this research is paused or no longer exists."
    }
    guard job.thread == agent.conversationID || agent.conversations.contains(where: { $0.id == job.thread })
      || agent.hub.run(for: job.thread) != nil else { return "The research chat no longer exists." }
    if let reason = placeRefusal(.web, for: owner, suggestOthers: false) { return reason }
    if let phase = job.followUp?.phase, [.planning, .searching, .selecting].contains(phase),
      SiteRules.rule(for: ResearchFollowUp.searchOrigin) != .normal || effectiveScope(owner)?.blocks(ResearchFollowUp.searchOrigin) == true {
      return "Public search is restricted by the current site rules. Research is paused."
    }
    for page in source.map({ [$0] }) ?? job.sources {
      if SiteRules.rule(for: page.url) != .normal || effectiveScope(owner)?.blocks(page.url) == true {
        return "This source is restricted by the current site rules. Research is paused."
      }
    }
    // A finished report can still be delivered when its AI app is disconnected.
    if !job.terminal {
      let provider = Provider(rawValue: job.provider)
      let route = assistantEngine(owner)
      guard route.provider == provider, route.model == job.model else {
        return "The assistant's AI route changed. This research keeps its original route; start new research with the new route."
      }
      guard provider.thinksForSerein, agent.available[provider] != nil else { return "Reconnect the AI app used for this research." }
      if let reason = HarnessRegistry.shared.verdict(provider, mode: "answer", edits: false, permission: .supervised).reason {
        return reason
      }
    }
    return nil
  }

  private func deliverResearch(_ job: ResearchJob) -> Bool {
    guard researchRefusal(job, source: nil) == nil, agent.hub.run(for: job.thread) == nil,
      !(sending && turnThread == job.thread),
      let index = agent.conversations.firstIndex(where: { $0.id == job.thread }) else { return false }
    // One stable message id closes the crash window between saving the reply and acknowledging
    // delivery in the notebook. Save first, then update the visible transcript.
    var saved = agent.conversations
    let inserted = job.updateReport(in: &saved[index].messages)
    if inserted {
      saved[index].lastMessageAt = Date()
    }
    saved[index].updatedAt = Date()
    do { try browser.library.save(saved, to: "sessions/threads.json") }
    catch { agent.error = error.localizedDescription; return false }
    agent.conversations = saved
    if agent.conversationID == job.thread {
      job.updateReport(in: &agent.messages)
      agent.saveConversation()
    }
    if let run = agent.hub.latest(for: job.thread) {
      job.updateReport(in: &run.transcript)
    }
    if inserted { noteReplyLanded(profileID: job.owner, thread: job.thread) }
    return true
  }
}

extension ResearchJob {
  /// Reuse the host-generated reply's identity and metadata when its status is corrected.
  @discardableResult func updateReport(in messages: inout [AgentMessage]) -> Bool {
    if let index = messages.firstIndex(where: { $0.id == messageID }) {
      messages[index].text = report
      return false
    }
    var message = AgentMessage(role: "assistant", text: report, notice: true)
    message.id = messageID
    // A background result belongs to the request that started it, even if a later question has
    // already been answered. Legacy jobs without an anchor retain their existing placement.
    if let requestedBy, let origin = messages.firstIndex(where: { $0.id == requestedBy }),
      let later = messages.indices.first(where: { $0 > origin && messages[$0].role == "you" }) {
      messages.insert(message, at: later)
    } else {
      messages.append(message)
    }
    return true
  }
}

extension RelayToolHost {
  func researchTool(_ name: String, _ a: [String: Any]) async throws -> [String: Any] {
    let coordinator = relay.research
    await coordinator.load()
    let thread = relay.turnThread
    let owner = relay.actingProfile?.id ?? relay.team.activeID
    if name == "research_start" {
      guard relay.working, relay.startedByPerson, !relay.runsUnattended else {
        throw SereinError.invalid("Only the person's request can start research that continues after a restart.")
      }
      guard let question = a["question"] as? String, let raw = a["sources"] as? [[String: Any]],
        raw.allSatisfy({ $0["url"] is String && $0["question"] is String }) else {
        throw SereinError.invalid("Give a research question and each source's URL and question.")
      }
      let sources = raw.map { ResearchJob.Source(url: $0["url"] as! String, question: $0["question"] as! String) }
      let route = relay.assistantEngine(relay.actingProfile)
      let request = relay.transcript.last(where: { $0.role == "you" })
      let findMore = (a["find_more_sources"] as? Bool ?? true) && !ResearchFollowUp.fixedSources(request?.text ?? "")
      let job = try ResearchJob(question: AgentPrivacy.redact(question), sources: sources, thread: thread, owner: owner,
                                provider: route.provider.rawValue, model: route.model,
                                requestedBy: request?.id, findMoreSources: findMore)
      try coordinator.start(job)
      return ["id": job.id, "state": job.state.rawValue, "sources": sources.count, "find_more_sources": findMore,
              "note": "Research started. Its card saves source and claim-check progress. A report with cited support, disagreements and limitations will return here. It can resume after a restart."]
    }
    let visible = coordinator.jobs.filter { $0.thread == thread && $0.owner == owner }
    if name == "research_status", a["id"] == nil {
      return ["jobs": visible.map(Self.researchStatus)]
    }
    guard let id = a["id"] as? String, let job = visible.first(where: { $0.id == id }) else {
      throw SereinError.invalid("That research job does not belong to this chat and assistant.")
    }
    switch name {
    case "research_cross_check":
      guard relay.working, relay.startedByPerson, !relay.runsUnattended else {
        throw SereinError.invalid("Only the person can request new comparisons for a saved report.")
      }
      guard let raw = a["sources"] as? [[String: Any]],
        raw.allSatisfy({ $0["url"] is String && $0["question"] is String }) else {
        throw SereinError.invalid("Give each new comparison source's URL and question.")
      }
      let sources = raw.map { ResearchJob.Source(url: $0["url"] as! String, question: $0["question"] as! String) }
      let route = relay.assistantEngine(relay.actingProfile)
      try coordinator.crossCheck(id, sources: sources, provider: route.provider.rawValue, model: route.model)
    case "research_pause": coordinator.pause(id)
    case "research_resume":
      guard relay.working, relay.startedByPerson, !relay.runsUnattended else {
        throw SereinError.invalid("Only the person can continue paused research.")
      }
      try coordinator.resume(id)
    default: break
    }
    return Self.researchStatus(coordinator.jobs.first(where: { $0.id == id }) ?? job)
  }

  private static func researchStatus(_ job: ResearchJob) -> [String: Any] {
    var out: [String: Any] = ["id": job.id, "state": job.state.rawValue, "completed": job.completed,
                            "total": job.sources.count, "question_untrusted": job.question]
    if job.terminal { out["status"] = job.reportTitle }
    if job.checksEnabled == true { out["claim_checks_untrusted"] = job.claimSummary }
    if let follow = job.followUp {
      out["evidence_follow_up"] = follow.phase.rawValue
      out["follow_up_untrusted"] = job.followUpReport.joined(separator: "\n")
    }
    if let note = job.note { out["note_untrusted"] = note }
    if job.terminal { out["report_untrusted"] = job.report }
    return out
  }
}
