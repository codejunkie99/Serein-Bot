#if DEBUG
import Foundation
import SereinCore

enum ResearchClaimFixtures {
  static func job(conflict: Bool = false) throws -> ResearchJob {
    var job = try ResearchJob(question: "How long does the fixture battery last in the same test?", sources: [
      .init(url: "https://example.com/test", question: "Team A's measurement"),
      .init(url: "https://example.org/test", question: "Team B's independent measurement"),
      .init(url: "https://example.net/test", question: "Team C's independent measurement"),
    ], thread: "claim-fixture-chat", owner: "main", provider: "synthetic", model: "fixture", requestedBy: "request")
    for index in job.sources.indices {
      let hours = conflict && index == 2 ? "six" : "ten"
      let text = "Team \(index) independently measured the fixture battery at \(hours) hours under the specified test conditions."
      try job.begin(index)
      try job.fetched(index, text: text)
      try job.checked(index, extraction: .init(findings: [.init(answer: "The battery lasts \(hours) hours in the specified test.", quote: text)]))
    }
    return job
  }
  static func review(_ job: ResearchJob, _ index: Int) -> ResearchClaimCheck {
    .init(claims: [.init(finding: 0, original: .supports, explanation: "The claim matches the reported test and conditions.",
      evidence: job.comparisonSources(index).map { page in
        .init(sourceID: page.id, quote: page.text ?? "", relation: page.findings[0].answer == job.sources[index].findings[0].answer ? .supports : .contradicts,
              independence: .independent, reason: "This synthetic source describes a separate team's own measurement under the same conditions.")
      })])
  }
}

extension AssistantCoreChecks {
  static func researchClaims(_ check: Check) throws {
    var job = try ResearchClaimFixtures.job(conflict: true)
    try check(job.runnable && job.next == nil && job.nextCheck == 0, "Checked sources wait for claim comparison before completing")
    let original = job
    var forged = ResearchClaimFixtures.review(job, 0)
    forged.claims[0].evidence[0].quote = "An invented measurement that nobody reported."
    do { try job.checkedClaims(0, result: forged); try check(false, "Invented comparison evidence must fail") }
    catch { try check(job == original, "A fabricated comparison quotation cannot change the saved claim") }
    forged = ResearchClaimFixtures.review(job, 0)
    forged.claims[0].evidence[0].sourceID = job.sources[0].id
    try check((try? job.verifyCheck(forged, at: 0)) == nil, "A claim cannot cite itself as independent evidence")
    forged.claims[0].evidence[0].sourceID = "unknown"
    try check((try? job.verifyCheck(forged, at: 0)) == nil, "Unknown comparison source IDs are rejected")
    try check((try? job.verifyCheck(.init(claims: []), at: 0)) == nil, "A comparison cannot silently omit claims")
    var verboseJob = original
    var verbose = ResearchClaimFixtures.review(verboseJob, 0)
    verbose.claims[0].explanation = String(repeating: "A detailed explanation. ", count: 50)
    verbose.claims[0].evidence[0].reason = String(repeating: "A detailed source assessment. ", count: 50)
    try verboseJob.checkedClaims(0, result: verbose)
    let kept = verboseJob.sources[0].claimCheck!.claims[0]
    try check(kept.explanation.count == 800 && kept.explanation.hasSuffix("[Explanation shortened.]")
                && kept.evidence[0].reason.hasSuffix("[Explanation shortened.]"),
              "Verbose model explanations are shortened visibly instead of blocking valid evidence")
    try check(kept.evidence.map(\.quote) == verbose.claims[0].evidence.map(\.quote) && kept.outcome == .disputed,
              "Shortening explanations preserves every quotation and the disagreement verdict")
    for index in job.sources.indices {
      try job.beginCheck(index)
      try job.checkedClaims(index, result: ResearchClaimFixtures.review(job, index))
    }
    try job.validate()
    try check(job.state == .ready && job.reportTitle == "Completed with limitations", "All claims checked with disagreement completes with limitations")
    try check(job.claimSummary.contains("3 with disagreements") && job.report.contains("at ten hours") && job.report.contains("at six hours") && job.report.contains("https://example.net/test"), "A disagreement retains both sides and their citations without a majority vote")
    try check(job.report.contains("AI-assessed") && job.report.contains("selected public pages"), "The report distinguishes semantic assessments from host-checked quotations and states coverage limits")
    let store = try ResearchStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("serein-claims-" + UUID().uuidString).appendingPathComponent("research.sqlite"))
    try store.save(job)
    try check(try store.jobs()[0] == job, "Claim results and their exact evidence survive SQLite reopening")
    var oversized = job
    oversized.note = String(repeating: "x", count: 2_000_001)
    do { try store.save(oversized); try check(false, "An unreadably large checkpoint must not be saved") }
    catch { try check(try store.jobs()[0] == job, "An oversized update preserves the previous readable checkpoint") }

    var supported = try ResearchClaimFixtures.job()
    let prompt = supported.claimCheckPrompt(0)
    try check(prompt.contains("untrusted data") && prompt.contains("counterevidence") && prompt.contains("Different domains are NOT proof") && prompt.contains(supported.sources[1].id), "The no-tool prompt asks for entailment, counterevidence and positive evidence of independence")
    var review = ResearchClaimFixtures.review(supported, 0)
    try check(review.claims[0].outcome == .supported, "Separate consistent evidence can support a claim")
    for index in review.claims[0].evidence.indices { review.claims[0].evidence[index].independence = .shared }
    try check(review.claims[0].outcome == .insufficient, "Shared reporting cannot establish independent support")
    for index in review.claims[0].evidence.indices { review.claims[0].evidence[index].independence = .uncertain }
    try check(review.claims[0].outcome == .insufficient, "An unknown source origin cannot establish independent support")
    review = ResearchClaimFixtures.review(supported, 0)
    review.claims[0].original = .unclear
    try check(review.claims[0].outcome == .insufficient, "Independent agreement cannot hide an unsupported original interpretation")
    for index in supported.sources.indices { try supported.checkedClaims(index, result: ResearchClaimFixtures.review(supported, index)) }
    try check(supported.state == .ready && supported.reportTitle == "Cross-checked research", "All supported comparisons can complete a cross-checked report")

    var sameSite = try ResearchClaimFixtures.job()
    sameSite.sources[1].url = "https://news.example.com/test"
    sameSite.sources[2].url = "https://www.example.com/other"
    try check(sameSite.comparisonSources(0).isEmpty, "Subdomains from the same publisher site do not count as independent candidates")
    var copy = try ResearchClaimFixtures.job()
    copy.sources[1].text = copy.sources[0].text
    copy.sources[1].digest = copy.sources[0].digest
    try check(copy.comparisonSources(0).map(\.id) == [copy.sources[2].id], "Identical snapshots on separate domains are excluded")
    for index in sameSite.sources.indices {
      try sameSite.checkedClaims(index, result: sameSite.unresolvedCheck(index, reason: "Only one publisher was selected."))
    }
    try check(sameSite.state == .ready && sameSite.claimSummary.contains("3 with insufficient"), "A completed comparison with no independent candidates reports insufficient evidence")
    var exhausted = try ResearchClaimFixtures.job()
    for _ in 0..<ResearchJob.maxAttempts { try exhausted.beginCheck(0) }
    try exhausted.beginCheck(0)
    try check(exhausted.nextCheck == 1 && exhausted.sources[0].claimCheck?.claims[0].outcome == .insufficient, "Interrupted comparisons retain a finite retry limit and never become verified by exhaustion")
    var premature = try ResearchClaimFixtures.job()
    premature.state = .ready
    try check((try? premature.validate()) == nil, "A job cannot validate as complete with pending claim checks")
    var legacy = supported
    legacy.checksEnabled = nil
    for index in legacy.sources.indices { legacy.sources[index].claimCheck = nil; legacy.sources[index].checkAttempts = nil }
    let decoded = try JSONDecoder().decode(ResearchJob.self, from: JSONEncoder().encode(legacy))
    try decoded.validate()
    try check(decoded.nextCheck == nil && decoded.report.contains("not been independently verified"), "Legacy notebooks decode without starting new comparison calls")

    var messages = [AgentMessage(id: "request", role: "you", text: "Research"), AgentMessage(role: "assistant", text: "Started"),
                    AgentMessage(id: "later", role: "you", text: "A newer question"), AgentMessage(role: "assistant", text: "The newer answer")]
    job.updateReport(in: &messages)
    try check(messages.map(\.id).firstIndex(of: job.messageID) == 2 && messages.last?.text == "The newer answer", "Delayed research lands before later user messages and leaves the latest answer last")
    job.updateReport(in: &messages)
    try check(messages.filter { $0.id == job.messageID }.count == 1, "Retrying anchored report delivery remains idempotent")
  }
}
#endif
