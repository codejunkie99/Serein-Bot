#if DEBUG
import Foundation
import SereinCore
import AppKit
import SwiftUI

/// Exercises the actual coordinator across new instances and SQLite connections. The network
/// and no-tool model are synthetic: no sign-ins, personal library or provider usage.
@MainActor enum ResearchChecks {
  private static func check(_ value: Bool, _ message: String) throws {
    guard value else { throw SereinError.invalid("FAIL: " + message) }
    print("PASS: " + message)
  }
  private static func until(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw SereinError.invalid("Timed out waiting for synthetic research.")
  }
  private static func file() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("serein-research-run-" + UUID().uuidString)
      .appendingPathComponent("research.sqlite")
  }
  private static func job() throws -> ResearchJob {
    try ResearchJob(question: "Research the library", sources: [
      .init(url: "https://example.com/solar", question: "What powers it?"),
      .init(url: "https://example.org/hours", question: "When does it open?"),
    ], thread: "synthetic-chat", owner: "main", provider: "synthetic", model: "fixture", checksEnabled: false)
  }
  private static func text(_ url: String) -> String {
    url.contains("solar") ? "The library uses solar panels on its roof." : "The library opens at nine every weekday."
  }
  private static func answer(_ job: ResearchJob, _ index: Int) -> ResearchJob.Extraction {
    .init(findings: [.init(answer: "The source states: " + (job.sources[index].text ?? ""), quote: job.sources[index].text ?? "")])
  }

  static func run() async throws {
    try await ResearchFollowUpChecks.run()
    try await ReplyStoryChecks.run()
    try await existingReportRecheck()
    try await claimCheckpoint()
    try await claimRevocation()
    try await fetchedCheckpoint()
    try await completedCheckpoint()
    try await stopAndRevocation()
    try await verificationAndDelivery()
    try await legacyCompletedReport()
    try await queuedStopAndMissingSource()
    try await damagedNotebook()
    if let captures = ProcessInfo.processInfo.environment["SEREIN_RESEARCH_CAPTURES"] {
      try await captureCards(at: URL(fileURLWithPath: captures, isDirectory: true))
    }
    if ProcessInfo.processInfo.environment["SEREIN_RESEARCH_LIVE_READ"] == "1" {
      let page = try await ResearchFetcher.read("https://example.com/")
      try check(page.contains("documentation examples"), "The public HTTPS reader fetches and extracts the expected example page without a model call")
    }
  }

  private static func existingReportRecheck() async throws {
    let url = file()
    var original = try ResearchClaimFixtures.job()
    original.sources = [original.sources[0]]
    original.checksEnabled = nil
    original.state = .ready
    original.delivered = true
    try ResearchStore(url: url).save(original)
    let references: [ResearchJob.Source] = [
      .init(url: "https://example.org/independent", question: "Separate test"),
      .init(url: "https://example.net/independent", question: "Counterevidence")]
    var reads: [String] = []
    var extractions = 0
    var comparisons = 0
    var held: CheckedContinuation<String, Error>?
    var allowed = false
    let snapshot = "A separate research team measured ten hours in the same test conditions."
    let first = ResearchCoordinator(file: url, authorize: { job, source in
      if job.terminal { return nil }
      return allowed && job.provider == "current" && source?.url != "https://blocked.example.org/" ? nil : "Not authorized"
    }, read: { address in
      reads.append(address)
      if address == references[1].url { return try await withCheckedThrowingContinuation { held = $0 } }
      return snapshot
    }, extract: { job, index in extractions += 1; return answer(job, index) }, deliver: { _ in true })
    await first.load()
    try check(first.jobs[0] == original && reads.isEmpty, "Opening a delivered legacy report does not spend usage or change its evidence")
    do {
      try first.crossCheck(original.id, sources: references, provider: "current", model: "new")
      try check(false, "A denied recheck must fail")
    } catch {
      try check(try ResearchStore(url: url).jobs()[0] == original, "Denied rechecks leave the completed report intact")
    }
    allowed = true
    let invalid = [[original.sources[0]], [.init(url: "https://localhost/", question: "Invalid")],
                   Array(repeating: references[0], count: ResearchJob.maxSources)]
    for sources in invalid {
      do {
        try first.crossCheck(original.id, sources: sources, provider: "current", model: "new")
        try check(false, "Invalid comparison sources must fail")
      } catch {
        try check(first.jobs[0] == original, "Invalid, duplicate or over-limit sources preserve the old report")
      }
    }
    do {
      try first.crossCheck(original.id, sources: [.init(url: "https://blocked.example.org/", question: "Blocked")], provider: "current", model: "new")
      try check(false, "A blocked source must fail")
    } catch {
      try check(first.jobs[0] == original, "Rechecks authorize every added page before saving")
    }
    try first.crossCheck(original.id, sources: references, provider: "current", model: "new")
    try await until { held != nil }
    try check(first.jobs[0].sources[0] == original.sources[0] && first.jobs[0].sources[1].state == .checked,
              "A recheck preserves original evidence and checkpoints comparison snapshots without extracting new claims")
    do {
      try first.crossCheck(original.id, sources: references, provider: "current", model: "new")
      try check(false, "An active recheck must not restart")
    } catch {
      try check(first.jobs[0].sources.count == 3, "Repeating a recheck request while it runs cannot duplicate sources")
    }
    first.shutdown()
    var delivered: [ResearchJob] = []
    let second = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { address in
      reads.append(address); return snapshot + " The report includes test measurements."
    }, extract: { job, index in extractions += 1; return answer(job, index) }, compare: { job, index in
      comparisons += 1
      return .init(claims: [.init(finding: 0, original: .supports, explanation: "Same test conditions.", evidence: [
        .init(sourceID: job.sources[1].id, quote: snapshot, relation: .supports, independence: .independent,
              reason: "Synthetic independent measurement.")])])
    }, deliver: { job in delivered.append(job); return true })
    await second.load()
    try await until { second.jobs.first?.delivered == true }
    held?.resume(returning: "Stale response that must not replace a saved snapshot.")
    await Task.yield()
    let result = second.jobs[0]
    try result.validate()
    try check(reads == [references[0].url, references[1].url, references[1].url] && extractions == 0 && comparisons == 1,
              "Restarted rechecks read only unfinished reference pages and compare only the original claims")
    try check(result.id == original.id && result.createdAt == original.createdAt && result.requestedBy == original.requestedBy
                && result.sources[0].findings == original.sources[0].findings && result.sources[0].text == original.sources[0].text
                && result.sources[0].fetchedAt == original.sources[0].fetchedAt && result.provider == "current",
              "Explicit rechecks keep the report identity and dated original evidence while using the selected AI route")
    try check(delivered.count == 1 && result.totalClaims == 1 && result.checkedClaims == 1
                && result.sources.dropFirst().allSatisfy({ $0.comparisonOnly == true && $0.claimCheck == nil && $0.findings.isEmpty }),
              "Comparison-only snapshots do not inflate claim coverage or require recursive comparisons")
    var messages = [AgentMessage(id: original.messageID, role: "assistant", text: original.report),
                    AgentMessage(role: "you", text: "A newer message")]
    let inserted = result.updateReport(in: &messages)
    try check(!inserted && messages.count == 2 && messages[0].text == result.report && messages[1].text == "A newer message",
              "The refreshed report replaces its existing message and leaves later messages in place")
    var forged = result
    forged.sources[1].findings = original.sources[0].findings
    try check((try? forged.validate()) == nil, "Decoded comparison-only sources cannot smuggle in additional claims")
    second.shutdown()
  }

  private static func claimCheckpoint() async throws {
    let url = file()
    let work = try ResearchClaimFixtures.job(conflict: true)
    try ResearchStore(url: url).save(work)
    var comparisons: [Int] = []
    var reads = 0
    var extractions = 0
    var held: CheckedContinuation<ResearchClaimCheck, Error>?
    let first = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { address in
      reads += 1; return text(address)
    }, extract: { job, index in extractions += 1; return answer(job, index) }, compare: { job, index in
      comparisons.append(index)
      if index == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
      return ResearchClaimFixtures.review(job, index)
    }, deliver: { _ in false })
    await first.load()
    try await until { held != nil }
    try check(first.jobs[0].sources[0].claimCheck != nil && first.jobs[0].sources[1].checkAttempts == 1,
              "Completed claim evidence and the next attempt are durable before interruption")
    let saved = first.jobs[0].sources[0].claimCheck
    first.shutdown()
    var delivered: [ResearchJob] = []
    let second = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { address in
      reads += 1; return text(address)
    }, extract: { job, index in extractions += 1; return answer(job, index) }, compare: { job, index in
      comparisons.append(index); return ResearchClaimFixtures.review(job, index)
    }, deliver: { job in delivered.append(job); return true })
    await second.load()
    try await until { second.jobs.first?.delivered == true }
    held?.resume(returning: work.unresolvedCheck(1, reason: "Stale interrupted result"))
    await Task.yield()
    try check(reads == 0 && extractions == 0 && comparisons == [0, 1, 1, 2],
              "Restart repeats only the interrupted comparison, not saved reads, extraction or completed checks")
    try check(second.jobs[0].sources[0].claimCheck == saved && second.jobs[0].sources[1].checkAttempts == 2,
              "Restart preserves comparison evidence and its finite attempt count")
    try check(delivered.count == 1 && delivered[0].reportTitle == "Completed with limitations" && delivered[0].claimSummary.contains("3 with disagreements"),
              "Resumed claim research delivers one completed report with visible disagreements")
    try check(!second.jobs[0].report.contains("Stale interrupted"), "A late comparison from the old worker cannot overwrite the resumed result")
    second.shutdown()
  }

  private static func claimRevocation() async throws {
    let url = file()
    let work = try ResearchClaimFixtures.job()
    try ResearchStore(url: url).save(work)
    var allowed = true
    var held: CheckedContinuation<ResearchClaimCheck, Error>?
    let runner = ResearchCoordinator(file: url, authorize: { _, _ in allowed ? nil : "Comparison source access revoked." },
      extract: { job, index in answer(job, index) }, compare: { _, _ in
        try await withCheckedThrowingContinuation { held = $0 }
      }, deliver: { _ in true })
    await runner.load()
    try await until { held != nil }
    allowed = false
    held?.resume(returning: ResearchClaimFixtures.review(work, 0))
    try await until { runner.jobs[0].state == .paused }
    try check(runner.jobs[0].sources[0].claimCheck == nil, "Revoking access during comparison prevents accepting the returned evidence")
    do { try runner.resume(work.id); try check(false, "Revoked comparisons cannot resume") }
    catch { try check(runner.jobs[0].state == .paused, "Continue rechecks every source used by the comparison") }
    runner.shutdown()
    allowed = true
    var invalid = ResearchClaimFixtures.review(work, 0)
    invalid.claims[0].evidence[0].quote = "This quotation was fabricated by the model."
    let retry = ResearchCoordinator(file: url, authorize: { _, _ in nil }, extract: { job, index in answer(job, index) },
      compare: { _, _ in invalid }, deliver: { _ in true })
    await retry.load()
    try retry.resume(work.id)
    try await until { retry.jobs[0].state == .paused }
    try check(retry.jobs[0].sources[0].claimCheck == nil && retry.jobs[0].note?.contains("not found") == true,
              "Fabricated comparison quotes pause with a clear reason and no verified result")
    retry.shutdown()

    let singleFile = file()
    var single = try ResearchClaimFixtures.job()
    single.sources[1].url = "https://example.com/second"
    single.sources[2].url = "https://example.com/third"
    try ResearchStore(url: singleFile).save(single)
    var calls = 0
    let noCandidates = ResearchCoordinator(file: singleFile, authorize: { _, _ in nil }, extract: { job, index in answer(job, index) },
      compare: { job, index in calls += 1; return ResearchClaimFixtures.review(job, index) }, deliver: { _ in true })
    await noCandidates.load()
    try await until { noCandidates.jobs[0].delivered }
    try check(calls == 0 && noCandidates.jobs[0].reportTitle == "Completed with limitations",
              "Same-publisher research completes honestly without spending a comparison model call")
    noCandidates.shutdown()
  }

  private static func fetchedCheckpoint() async throws {
    let url = file()
    var reads: [String] = []
    var held: CheckedContinuation<ResearchJob.Extraction, Error>?
    let first = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { address in
      reads.append(address); return text(address)
    }, extract: { _, _ in try await withCheckedThrowingContinuation { held = $0 } }, deliver: { _ in false })
    await first.load()
    let work = try job()
    try first.start(work)
    try await until { held != nil }
    try check(first.jobs[0].sources[0].state == .fetched, "The page is durable before the model reads it")
    first.shutdown()
    var delivered: [ResearchJob] = []
    let second = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { address in
      reads.append(address); return text(address)
    }, extract: { job, index in answer(job, index) }, deliver: { job in delivered.append(job); return true })
    await second.load()
    try await until { second.jobs.first?.delivered == true }
    held?.resume(throwing: CancellationError())
    try check(reads == work.sources.map(\.url), "Restart after a saved GET extracts that snapshot without fetching it twice")
    try check(delivered.count == 1 && delivered[0].state == .ready, "Resumed research delivers one source-checked result")
    try check(second.jobs[0].sources.allSatisfy { $0.state == .checked }, "All reported sources have checked evidence")
    second.shutdown()
  }

  private static func completedCheckpoint() async throws {
    let url = file()
    var reads: [String] = []
    var held: CheckedContinuation<String, Error>?
    let first = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { address in
      reads.append(address)
      if address.contains("hours") { return try await withCheckedThrowingContinuation { held = $0 } }
      return text(address)
    }, extract: { job, index in answer(job, index) }, deliver: { _ in false })
    await first.load()
    let work = try job()
    try first.start(work)
    try await until { held != nil }
    first.shutdown()
    let savedFinding = first.jobs[0].sources[0].findings
    let second = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { address in
      reads.append(address); return text(address)
    }, extract: { job, index in answer(job, index) }, deliver: { _ in true })
    await second.load()
    try await until { second.jobs.first?.delivered == true }
    held?.resume(returning: "Stale old request that must never replace saved evidence.")
    await Task.yield()
    try check(reads.filter { $0.contains("solar") }.count == 1, "A completed source is never repeated after restart")
    try check(second.jobs[0].sources[0].findings == savedFinding, "Restart retains checked findings unchanged")
    try check(second.jobs[0].sources[1].text == text(work.sources[1].url), "A late result from the interrupted worker cannot overwrite its replacement")
    second.shutdown()
  }

  private static func stopAndRevocation() async throws {
    let url = file()
    var allowed = true
    var held: CheckedContinuation<String, Error>?
    var reads = 0
    var models = 0
    let first = ResearchCoordinator(file: url, authorize: { _, _ in allowed ? nil : "Web access was revoked." }, read: { _ in
      reads += 1
      return try await withCheckedThrowingContinuation { held = $0 }
    }, extract: { job, index in models += 1; return answer(job, index) }, deliver: { _ in true })
    await first.load()
    let work = try job()
    try first.start(work)
    try await until { held != nil }
    allowed = false
    held?.resume(returning: text(work.sources[0].url))
    try await until { first.jobs.first?.state == .paused }
    try check(models == 0 && first.jobs[0].sources[0].text == nil, "Revocation during a read prevents using its result or calling a model")
    first.shutdown()
    let second = ResearchCoordinator(file: url, authorize: { _, _ in allowed ? nil : "Web access was revoked." }, read: { address in
      reads += 1; return text(address)
    }, extract: { job, index in models += 1; return answer(job, index) }, deliver: { _ in true })
    await second.load()
    second.tick()
    try check(reads == 1 && !second.isWorking, "A paused job remains paused after reopening")
    do { try second.resume(work.id); try check(false, "Revoked access must refuse Continue") } catch {
      try check(!second.isWorking, "Continue rechecks live permission")
    }
    allowed = true
    try second.resume(work.id)
    second.pauseAll() // Before the queued Task gets its first turn.
    await Task.yield()
    try check(reads == 1 && second.jobs[0].state == .paused, "Stop Everything prevents the queued request and persists its pause")
    second.forget(thread: work.thread)
    try check(try ResearchStore(url: url).jobs().isEmpty, "Deleting a chat removes its saved research")
    second.shutdown()
  }

  private static func verificationAndDelivery() async throws {
    let url = file()
    var ready = false
    var reads = 0
    var messages: Set<String> = []
    var deliveries = 0
    let first = ResearchCoordinator(file: url, ready: { _ in ready }, authorize: { _, _ in nil }, read: { address in
      reads += 1; return text(address)
    }, extract: { job, index in
      index == 0 ? answer(job, index) : .init(findings: [.init(answer: "Invented result", quote: "This quotation does not exist in the page.")])
    }, deliver: { job in
      if messages.insert(job.messageID).inserted { deliveries += 1 }
      return false // The reply was saved, then the process died before acknowledging it.
    })
    await first.load()
    try first.start(try job())
    await Task.yield()
    try check(reads == 0, "Launch waits for AI app discovery before starting research")
    ready = true
    first.tick()
    try await until { deliveries == 1 }
    try check(first.jobs[0].state == .incomplete && !first.jobs[0].report.contains("Invented result"), "Fabricated quotations cannot appear as verified findings")
    first.shutdown()
    let second = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { _ in
      throw SereinError.invalid("Finished research must not fetch again")
    }, extract: { _, _ in throw SereinError.invalid("Finished research must not call a model") }, deliver: { job in
      if messages.insert(job.messageID).inserted { deliveries += 1 }
      return true
    })
    await second.load()
    try check(deliveries == 1 && second.jobs[0].delivered, "Restart in the delivery window reuses the reply identity and does not duplicate the result")
    second.shutdown()
  }

  private static func damagedNotebook() async throws {
    let url = file()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let damaged = Data("A damaged notebook, preserved for recovery".utf8)
    try damaged.write(to: url)
    let coordinator = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { _ in
      throw SereinError.invalid("A damaged notebook must not run")
    }, extract: { _, _ in throw CancellationError() }, deliver: { _ in false })
    await coordinator.load()
    try check(coordinator.problem != nil && (try Data(contentsOf: url)) == damaged, "Unreadable research is preserved and starts no work")
    coordinator.shutdown()
  }

  private static func legacyCompletedReport() async throws {
    let url = file()
    var work = try job()
    let caveat = "These pages describe the library, not an independent inspection."
    for index in work.sources.indices {
      try work.begin(index)
      try work.fetched(index, text: text(work.sources[index].url))
      var extraction = answer(work, index)
      extraction.limitation = caveat
      try work.checked(index, extraction: extraction)
    }
    work.state = .incomplete // A report saved by the previous app.
    work.delivered = true
    try ResearchStore(url: url).save(work)
    var messages = [AgentMessage(role: "user", text: "Keep this conversation.")]
    work.updateReport(in: &messages)
    messages[1].text = messages[1].text.replacingOccurrences(of: "Limitation: ", with: "Not verified: ")
    let original = messages
    let evidence = work.sources
    var calls = 0
    var deliveries = 0
    var allowDelivery = false
    func coordinator() -> ResearchCoordinator {
      ResearchCoordinator(file: url, authorize: { _, _ in allowDelivery ? nil : "Assistant paused." }, read: { _ in
        calls += 1; throw CancellationError()
      }, extract: { _, _ in calls += 1; throw CancellationError() }, deliver: { job in
        deliveries += 1
        job.updateReport(in: &messages)
        return false // Simulate losing the acknowledgement after the corrected reply is saved.
      })
    }
    let first = coordinator()
    await first.load()
    try check(first.jobs[0].state == .ready && !first.jobs[0].delivered && deliveries == 0,
              "Legacy fully checked research is completed, with report correction waiting for current permission")
    try check(try ResearchStore(url: url).jobs()[0].state == .ready,
              "The corrected completion state is saved before report delivery")
    allowDelivery = true
    first.tick()
    try check(messages.count == original.count && messages[0] == original[0]
                && messages[1].id == original[1].id && messages[1].text.hasPrefix("Completed with limitations\n"),
              "Legacy report is corrected in place without adding a message or changing other messages")
    var expected = original[1]
    expected.text = work.report.replacingOccurrences(of: "Research — incomplete\n", with: "Completed with limitations\n")
    try check(messages[1] == expected && messages[1].text.contains("Limitation: " + caveat),
              "Correcting the report preserves its metadata and caveats")
    first.shutdown()
    let second = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { _ in
      calls += 1; throw CancellationError()
    }, extract: { _, _ in calls += 1; throw CancellationError() }, deliver: { job in
      deliveries += 1
      job.updateReport(in: &messages)
      return true
    })
    await second.load()
    try check(second.jobs[0].delivered && second.jobs[0].sources == evidence && calls == 0 && messages.count == original.count,
              "Restart during a report correction preserves all evidence and uses no network or model calls")
    let count = deliveries
    second.shutdown()
    let third = coordinator()
    await third.load()
    try check(third.jobs[0].delivered && deliveries == count,
              "A corrected, acknowledged report is not delivered again after restart")
    third.shutdown()
  }

  private static func queuedStopAndMissingSource() async throws {
    var held: CheckedContinuation<String, Error>?
    var reads = 0
    let coordinator = ResearchCoordinator(file: file(), authorize: { _, _ in nil }, read: { address in
      reads += 1
      if address.contains("solar") { return try await withCheckedThrowingContinuation { held = $0 } }
      throw ResearchReadFailure.unavailable("The public page is gone.")
    }, extract: { job, index in answer(job, index) }, deliver: { _ in true })
    await coordinator.load()
    let first = try job()
    var queued = try job()
    queued.thread = "another-chat"
    try coordinator.start(first)
    try await until { held != nil }
    try coordinator.start(queued)
    coordinator.pause(queued.id)
    held?.resume(returning: text(first.sources[0].url))
    try await until { coordinator.jobs.first?.delivered == true }
    try check(reads == 2 && coordinator.jobs[0].sources[0].attempts == 1, "Stopping a queued job does not interrupt another chat's running research")
    try check(coordinator.jobs[0].state == .incomplete && coordinator.jobs[0].sources[1].state == .unavailable,
              "An unavailable page is recorded as missing evidence while the report still completes")
    coordinator.shutdown()
  }

  private static func captureCards(at directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = file()
    var work = try job()
    try work.begin(0)
    try work.fetched(0, text: text(work.sources[0].url))
    try work.begin(0)
    try work.checked(0, extraction: answer(work, 0))
    work.state = .paused
    work.note = "Progress was saved before Serein closed. Continue with the remaining source."
    try ResearchStore(url: url).save(work)
    let coordinator = ResearchCoordinator(file: url, authorize: { _, _ in nil }, read: { _ in throw CancellationError() },
      extract: { _, _ in throw CancellationError() }, deliver: { _ in false })
    await coordinator.load()
    for palette in [Palette.light, .dusk] {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                            styleMask: [.borderless], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
      let host = NSHostingView(rootView: ResearchCards(research: coordinator, thread: work.thread)
        .padding(20).frame(width: 440, height: 320, alignment: .topLeading)
        .environment(\.palette, palette).environment(\.sereinReducedEffects, true).background(palette.background))
      window.contentView = host
      window.orderFront(nil)
      try await Task.sleep(nanoseconds: 150_000_000)
      host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw SereinError.invalid("The research card could not be rendered.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw SereinError.invalid("The research card image is empty.")
      }
      try png.write(to: directory.appendingPathComponent(palette.isDark ? "research-dark.png" : "research-light.png"))
      window.close()
    }
    coordinator.shutdown()
    try check(true, "Rendered the real research card in light and dark palettes")
  }
}
#endif
