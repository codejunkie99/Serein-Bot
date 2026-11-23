#if DEBUG
import Foundation
import SereinCore

@MainActor enum ResearchFollowUpChecks {
  private static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw SereinError.invalid("FAIL: " + message) }
    print("PASS: " + message)
  }
  private static func until(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw SereinError.invalid("Timed out waiting for evidence follow-up.")
  }
  private static func file() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("serein-follow-up-" + UUID().uuidString)
      .appendingPathComponent("research.sqlite")
  }
  private static let original = "The battery lasted ten hours under the stated laboratory conditions."
  private static let separate = "Our independent test measured ten hours using the stated laboratory conditions."
  private static func job(enabled: Bool = true) throws -> ResearchJob {
    try ResearchJob(question: "Research battery life", sources: [
      .init(url: "https://example.com/battery", question: "What was measured?")
    ], thread: "synthetic", owner: "main", provider: "fixture", model: "fixture", findMoreSources: enabled)
  }
  private static func extraction(_ job: ResearchJob, _ index: Int) -> ResearchJob.Extraction {
    .init(findings: [.init(answer: "Battery life was ten hours in the test.", quote: original)])
  }
  private static func review(_ job: ResearchJob, _ index: Int) -> ResearchClaimCheck {
    .init(claims: [.init(finding: 0, original: .supports, explanation: "The conditions match.", evidence: [
      .init(sourceID: job.sources[1].id, quote: separate, relation: .supports, independence: .independent,
            reason: "An independent measurement in the synthetic fixture.")])])
  }
  static func run() async throws {
    try parsing()
    try limitsAndStrongEvidence()
    try await resumedSearch()
    try await boundedFailures()
    try await revocation()
    if ProcessInfo.processInfo.environment["SEREIN_RESEARCH_LIVE_SEARCH"] == "1" {
      let candidates = try await ResearchFetcher.search("SQLite fsync failure independent study")
      try check(!candidates.isEmpty, "Live public search returns validated page leads without a model call")
    }
  }
  private static func parsing() throws {
    let html = """
      <a href="https://example.com/ignored">Not a result</a>
      <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fstudy&amp;rut=abc">A &amp; B</a>
      <a class="result__a" href="https://localhost/private">Private</a>
      <a class="result__a" href="https://example.org/study">Duplicate</a>
      <a class="result__a" href="https://example.net/test?token=secret">Query URL</a>
      <a class="result__a" href="https://example.net/test">Independent test</a>
      """
    let results = try ResearchFollowUp.candidates(in: html)
    try check(results.map(\.url) == ["https://example.org/study", "https://example.net/test"], "Search leads accept only observed public result links, deduplicate and reject private/query URLs")
    try check(results[0].title == "A & B", "Search result titles decode HTML entities")
    do { _ = try ResearchFollowUp.candidates(in: "<form id=\"challenge-form\">"); throw SereinError.invalid("Challenge accepted") }
    catch { try check(error.localizedDescription.contains("verification challenge"), "Search challenges are explicit failures, not empty successful searches") }
    let address = try ResearchFollowUp.searchURL("battery life & independent test")
    try check(address.host == "html.duckduckgo.com" && URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "battery life & independent test", "Search queries cannot change the fixed host or escape their query item")
    for query in ["", String(repeating: "x", count: 201), "topic\nother", "my api_key=sk-secret-secret-secret-secret"] {
      try check((try? ResearchFollowUp.searchURL(query)) == nil, "Invalid or sensitive public search text is rejected")
    }
    try check(ResearchFollowUp.fixedSources("Use only these sources") && ResearchFollowUp.fixedSources("Use exactly four direct public HTTPS sources") && !ResearchFollowUp.fixedSources("Start with this source"), "Fixed source lists close discovery while starting points allow it")
  }
  private static func limitsAndStrongEvidence() throws {
    var work = try job()
    try work.begin(0); try work.fetched(0, text: original); try work.checked(0, extraction: extraction(work, 0))
    try work.beginCheck(0); try work.checkedClaims(0, result: work.unresolvedCheck(0, reason: "Missing independent evidence"))
    do {
      try work.plannedFollowUp(.init(queries: ["a", "b", "c"], reason: "Too many"))
      try check(false, "More than two queries must fail")
    } catch { try check(work.followUp?.searches.isEmpty == true, "An over-limit plan cannot create searches") }
    try work.plannedFollowUp(.init(queries: ["battery independent tests"], reason: "Missing separate measurement"))
    work.followUp?.searches[0].candidates = (1...4).map { .init(url: "https://example.org/test\($0)", title: "Test") }
    work.followUp?.searches[0].searchedAt = Date()
    work.followUp?.phase = .selecting
    do {
      try work.selectedFollowUp(work.followUpCandidates.map(\.url))
      try check(false, "More than three pages must fail")
    } catch { try check(work.sources.count == 1, "An over-limit selection cannot append partial sources") }
    try work.selectedFollowUp(Array(work.followUpCandidates.prefix(3)).map(\.url))
    try check(work.sources.count == 4 && work.sources.dropFirst().allSatisfy { $0.comparisonOnly == true }, "The bounded pass adds at most three comparison-only pages")
    var strong = try job()
    var reference = ResearchJob.Source(url: "https://example.org/study", question: "Separate measurement")
    reference.comparisonOnly = true
    strong.sources.append(reference)
    try strong.begin(0); try strong.fetched(0, text: original); try strong.checked(0, extraction: extraction(strong, 0))
    try strong.begin(1); try strong.fetched(1, text: separate)
    try strong.beginCheck(0); try strong.checkedClaims(0, result: review(strong, 0))
    try strong.validate()
    try check(strong.state == .ready && strong.followUp?.phase == .done && strong.followUp?.searches.isEmpty == true, "Already-supported claims finish without spending usage on discovery")
  }
  private static func resumedSearch() async throws {
    let url = file()
    let work = try job()
    var reads: [String] = []
    var extracts = 0, plans = 0, selections = 0, comparisons = 0
    var queries: [String] = []
    var held: CheckedContinuation<[ResearchFollowUp.Candidate], Error>?
    let first = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { address in
      reads.append(address); return original
    }, extract: { job, index in extracts += 1; return extraction(job, index) }, plan: { _ in
      plans += 1; return .init(queries: ["battery measurements", "battery counterevidence"], reason: "Only the original publisher was checked.")
    }, search: { query in
      queries.append(query)
      if queries.count == 2 { return try await withCheckedThrowingContinuation { held = $0 } }
      return [.init(url: "https://example.org/study", title: "Independent measurements")]
    }, deliver: { _ in true })
    await first.load(); try first.start(work)
    try await until { held != nil }
    let checkpoint = first.jobs[0]
    try check(checkpoint.followUp?.phase == .searching && checkpoint.followUp?.initialChecks.count == 1, "Weak initial claims trigger a saved follow-up without another user request")
    try check(checkpoint.followUp?.searches[0].searchedAt != nil && checkpoint.followUp?.searches[1].attempts == 1, "Completed search and interrupted attempt are checkpointed separately")
    first.shutdown()
    var reports = 0
    let second = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { address in
      reads.append(address); return separate
    }, extract: { job, index in extracts += 1; return extraction(job, index) }, compare: { job, index in
      comparisons += 1; return review(job, index)
    }, plan: { _ in plans += 1; throw SereinError.invalid("Must not replan") }, search: { query in
      queries.append(query); return [.init(url: "https://example.net/counter", title: "Counterevidence")]
    }, select: { job in
      selections += 1
      return .init(urls: [job.followUpCandidates[0].url])
    }, deliver: { _ in reports += 1; return true })
    await second.load()
    try await until { second.jobs.first?.delivered == true }
    held?.resume(returning: [.init(url: "https://example.net/stale", title: "Stale")])
    await Task.yield()
    let finished = second.jobs[0]
    try check(plans == 1 && queries == ["battery measurements", "battery counterevidence", "battery counterevidence"], "Restart repeats only the unfinished search, preserving its plan and completed query")
    try check(reads == [work.sources[0].url, "https://example.org/study"] && extracts == 1, "Follow-up preserves original reads and extractions and only reads selected comparison pages")
    try check(finished.sources[0].text == checkpoint.sources[0].text && finished.sources[0].findings == checkpoint.sources[0].findings && finished.sources[0].fetchedAt == checkpoint.sources[0].fetchedAt, "Original evidence and date survive the additional comparison unchanged")
    try check(finished.followUp?.initialChecks[work.sources[0].id]?.claims[0].outcome == .insufficient && finished.sources[0].claimCheck?.claims[0].outcome == .supported, "Initial uncertainty remains auditable when new verified passages support the claim")
    try check(finished.followUp?.phase == .done && comparisons == 1 && selections == 1 && reports == 1, "Discovery is one bounded pass and delivers one report")
    second.shutdown()
    let third = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { _ in throw SereinError.invalid("No reread") }, extract: extraction, deliver: { _ in reports += 1; return true })
    await third.load(); await Task.yield()
    try check(third.jobs[0] == finished && reports == 1, "Reopening a finished follow-up starts no new work or delivery")
    third.shutdown()
  }
  private static func boundedFailures() async throws {
    for mode in ["fixed", "plan", "search", "invented", "unreadable"] {
      var plans = 0, searches = 0, selections = 0, referenceReads = 0
      let work = try job(enabled: mode != "fixed")
      let runner = ResearchCoordinator(file: file(), authorize: { _, _ in nil }, read: { address in
        if address == work.sources[0].url { return original }
        referenceReads += 1
        throw SereinError.invalid("Transient page failure")
      }, extract: extraction, plan: { _ in
        plans += 1
        if mode == "plan" { throw SereinError.invalid("Planner unavailable") }
        return .init(queries: ["battery independent measurements"], reason: "Missing independent observation")
      }, search: { _ in
        searches += 1
        if mode == "search" { throw SereinError.invalid("Search unavailable") }
        return [.init(url: "https://example.org/study", title: "Measurement")]
      }, select: { _ in
        selections += 1
        return .init(urls: [mode == "invented" ? "https://example.net/invented" : "https://example.org/study"])
      }, deliver: { _ in true })
      await runner.load(); try runner.start(work)
      try await until { runner.jobs.first?.delivered == true }
      let result = runner.jobs[0]
      try check(result.sources[0].claimCheck?.claims[0].outcome == .insufficient, "\(mode): failures preserve the initial unresolved assessment")
      switch mode {
      case "fixed": try check(plans == 0 && searches == 0 && result.followUp == nil, "Fixed and legacy jobs never silently expand their source scope")
      case "plan": try check(plans == 3 && searches == 0 && result.followUp?.limitation != nil, "Planner failures stop at the persisted retry limit with a limitation")
      case "search": try check(searches == 3 && selections == 0 && result.followUp?.searches[0].limitation != nil, "Search failures are bounded and remain visible in the report")
      case "invented": try check(selections == 3 && referenceReads == 0, "Invented selector URLs never get fetched and cannot retry forever")
      default: try check(referenceReads == 3 && result.followUp?.limitation != nil, "Unavailable added pages exhaust their retry limit without discarding the first assessment")
      }
      runner.shutdown()
    }
  }
  private static func revocation() async throws {
    var allowed = true
    var held: CheckedContinuation<[ResearchFollowUp.Candidate], Error>?
    var selections = 0
    let runner = ResearchCoordinator(file: file(), authorize: { _, _ in allowed ? nil : "Revoked" }, read: { _ in original }, extract: extraction, plan: { _ in
      .init(queries: ["battery observation"], reason: "Independent evidence is missing")
    }, search: { _ in try await withCheckedThrowingContinuation { held = $0 } }, select: { _ in
      selections += 1; return .init(urls: [])
    }, deliver: { _ in true })
    await runner.load(); try runner.start(job())
    try await until { held != nil }
    allowed = false
    held?.resume(returning: [.init(url: "https://example.org/study", title: "Revoked result")])
    try await until { runner.jobs.first?.state == .paused }
    try check(runner.jobs[0].followUp?.searches[0].candidates == nil && selections == 0, "Revoking access during search pauses before accepting results or starting selection")
    runner.shutdown()
  }
}
#endif
