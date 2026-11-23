import Foundation
import SereinCore

/// One source at a time, with a committed checkpoint between every asynchronous operation.
/// Authorization is supplied by the live shell, not read from the notebook. The closures also
/// let restart checks use synthetic sources and answers without a provider call or real network.
@MainActor final class ResearchCoordinator: ObservableObject {
  @Published private(set) var jobs: [ResearchJob] = []
  @Published private(set) var problem: String?
  private let file: URL
  private let ready: (ResearchJob) -> Bool
  private let authorize: (ResearchJob, ResearchJob.Source?) -> String?
  private let read: (String) async throws -> String
  private let extract: (ResearchJob, Int) async throws -> ResearchJob.Extraction
  private let compare: (ResearchJob, Int) async throws -> ResearchClaimCheck
  private let plan: (ResearchJob) async throws -> ResearchFollowUp.Plan
  private let search: (String) async throws -> [ResearchFollowUp.Candidate]
  private let select: (ResearchJob) async throws -> ResearchFollowUp.Selection
  private let deliver: (ResearchJob) -> Bool
  private var store: ResearchStore?
  private var loading = false
  private var worker: Task<Void, Never>?
  private var workerJob: String?
  private var epoch = 0
  private var stopped = false
  private var forgotten: Set<String> = []
  var isWorking: Bool { jobs.contains { $0.runnable } }

  init(file: URL, ready: @escaping (ResearchJob) -> Bool = { _ in true },
       authorize: @escaping (ResearchJob, ResearchJob.Source?) -> String?,
       read: @escaping (String) async throws -> String = ResearchFetcher.read,
       extract: @escaping (ResearchJob, Int) async throws -> ResearchJob.Extraction,
       compare: @escaping (ResearchJob, Int) async throws -> ResearchClaimCheck = { _, _ in
         throw SereinError.invalid("Claim checking is not available.")
       },
       plan: @escaping (ResearchJob) async throws -> ResearchFollowUp.Plan = { _ in
         throw SereinError.invalid("Evidence follow-up planning is not available.")
       },
       search: @escaping (String) async throws -> [ResearchFollowUp.Candidate] = ResearchFetcher.search,
       select: @escaping (ResearchJob) async throws -> ResearchFollowUp.Selection = { _ in
         throw SereinError.invalid("Evidence follow-up selection is not available.")
       },
       deliver: @escaping (ResearchJob) -> Bool) {
    self.file = file
    self.ready = ready
    self.authorize = authorize
    self.read = read
    self.extract = extract
    self.compare = compare
    self.plan = plan
    self.search = search
    self.select = select
    self.deliver = deliver
  }

  func load() async {
    guard store == nil, !loading, problem == nil else { return }
    loading = true
    defer { loading = false }
    do {
      let file = file
      let (opened, saved) = try await Task.detached(priority: .utility) {
        let opened = try ResearchStore(url: file)
        return (opened, try opened.jobs())
      }.value
      store = opened
      jobs = saved
      // Older notebooks treated a checked source's caveat as unfinished research. Repair the
      // outcome and refresh its existing reply by stable id, without repeating reads or extraction.
      for var job in saved where job.state == .incomplete && job.nextCheck == nil && !job.followUpStep && job.sources.allSatisfy({ $0.state == .checked }) {
        job.state = .ready
        job.delivered = false
        try save(job)
      }
      for thread in forgotten { forget(thread: thread) }
      // Stop during the open must also stop jobs not loaded yet.
      if stopped { pauseAll() }
      tick()
    } catch { problem = "Research progress could not be read. It has been preserved. " + error.localizedDescription }
  }

  func start(_ job: ResearchJob) throws {
    guard store != nil, problem == nil else { throw SereinError.invalid(problem ?? "The research notebook is still opening.") }
    guard jobs.count < ResearchJob.maxJobs else { throw SereinError.invalid("The research notebook is full.") }
    guard !jobs.contains(where: { $0.thread == job.thread && !$0.terminal }) else {
      throw SereinError.invalid("This chat already has unfinished research. Check its status or continue it first.")
    }
    if let reason = authorize(job, nil) { throw SereinError.invalid(reason) }
    for source in job.sources {
      if let reason = authorize(job, source) { throw SereinError.invalid(reason) }
    }
    try save(job)
    stopped = false
    tick()
  }

  func pause(_ id: String) {
    guard var job = jobs.first(where: { $0.id == id }), !job.terminal else { return }
    if workerJob == id { invalidate() }
    job.state = .paused
    job.note = "Paused. Checked sources are saved."
    do { try save(job) } catch { failSaving(error) }
    tick()
  }

  func crossCheck(_ id: String, sources: [ResearchJob.Source], provider: String, model: String) throws {
    guard store != nil, problem == nil, let original = jobs.first(where: { $0.id == id }) else {
      throw SereinError.invalid(problem ?? "The research report is not available.")
    }
    guard !jobs.contains(where: { $0.thread == original.thread && !$0.terminal }) else {
      throw SereinError.invalid("This chat already has unfinished research. Continue or end it first.")
    }
    let updated = try original.crossChecking(with: sources, provider: provider, model: model)
    if let reason = authorize(updated, nil) { throw SereinError.invalid(reason) }
    for source in updated.sources {
      if let reason = authorize(updated, source) { throw SereinError.invalid(reason) }
    }
    try save(updated)
    stopped = false
    tick()
  }

  func pauseAll() {
    stopped = true
    invalidate()
    for var job in jobs where job.runnable {
      job.state = .paused
      job.note = "Stopped. Choose Continue when you want to resume this research."
      do { try save(job) } catch { failSaving(error); break }
    }
  }

  func end(_ id: String) {
    guard var job = jobs.first(where: { $0.id == id }), !job.terminal else { return }
    if workerJob == id { invalidate() }
    job.state = .cancelled
    job.delivered = true
    job.note = "Research ended."
    do { try save(job) } catch { failSaving(error) }
    tick()
  }

  /// Quitting cancels in-flight reads without pausing their saved checkpoint.
  func shutdown() { stopped = true; invalidate() }

  func forget(thread: String) {
    forgotten.insert(thread)
    if jobs.contains(where: { $0.thread == thread && $0.id == workerJob }) { invalidate() }
    do {
      for job in jobs where job.thread == thread { try store?.remove(id: job.id) }
      jobs.removeAll { $0.thread == thread }
    } catch { failSaving(error) }
    tick()
  }

  func resume(_ id: String) throws {
    guard var job = jobs.first(where: { $0.id == id }), job.state == .paused else {
      throw SereinError.invalid("That research job is not paused.")
    }
    if let reason = authorize(job, nil) { throw SereinError.invalid(reason) }
    for source in job.sources where !source.finished {
      if let reason = authorize(job, source) { throw SereinError.invalid(reason) }
    }
    job.state = .queued
    job.note = nil
    try save(job)
    stopped = false
    tick()
  }

  /// Called at launch and by the existing clock. Completed results retry delivery with a stable
  /// message identity; a busy chat or a crash between delivery and acknowledgement cannot duplicate it.
  func tick() {
    guard store != nil, problem == nil else { return }
    for var job in jobs where job.terminal && job.state != .cancelled && !job.delivered {
      guard authorize(job, nil) == nil, deliver(job) else { continue }
      job.delivered = true
      do { try save(job) } catch { failSaving(error); return }
    }
    guard !stopped, worker == nil, let job = jobs.first(where: { $0.runnable && ready($0) }) else { return }
    let generation = epoch
    workerJob = job.id
    worker = Task { [weak self] in
      guard let self else { return }
      await run(job.id, generation: generation)
      guard generation == epoch else { return }
      worker = nil
      workerJob = nil
      tick()
    }
  }

  private func run(_ id: String, generation: Int) async {
    while generation == epoch, !Task.isCancelled, var job = jobs.first(where: { $0.id == id }), job.runnable {
      if job.followUpStep {
        await advanceFollowUp(job, generation: generation)
        continue
      }
      if let index = job.nextCheck {
        // A comparison reads all selected snapshots, so recheck access to every source.
        if let reason = authorize(job, nil) {
          job.state = .paused
          job.note = reason
          do { try save(job) } catch { failSaving(error) }
          return
        }
        do {
          try job.beginCheck(index)
          try save(job)
        } catch { failSaving(error); return }
        if job.sources[index].claimCheck != nil { continue }
        do {
          let result: ResearchClaimCheck
          if job.comparisonSources(index).isEmpty {
            result = job.unresolvedCheck(index, reason: "No eligible comparison page from another site was saved. Same-site pages and identical copies cannot establish independent support.")
          } else {
            result = try await compare(job, index)
          }
          guard generation == epoch, !Task.isCancelled else { return }
          if let reason = authorize(job, nil) { throw SereinError.invalid(reason) }
          try job.checkedClaims(index, result: result)
        } catch {
          guard generation == epoch, !Task.isCancelled else { return }
          job.state = job.followUp?.phase == .checking ? .running : .paused
          job.note = String(AgentPrivacy.redact(error.localizedDescription).prefix(600))
        }
        do { try save(job) } catch { failSaving(error); return }
        continue
      }
      guard let index = job.next else { return }
      if let reason = authorize(job, job.sources[index]) {
        job.state = .paused
        job.note = reason
        do { try save(job) } catch { failSaving(error) }
        return
      }
      do {
        try job.begin(index)
        try save(job) // Persist the attempt before spending network or model usage.
      } catch { failSaving(error); return }
      if job.sources[index].finished { continue }
      do {
        if job.sources[index].state == .pending {
          let text = try await read(job.sources[index].url)
          guard generation == epoch, !Task.isCancelled else { return }
          if let reason = authorize(job, job.sources[index]) { throw SereinError.invalid(reason) }
          try job.fetched(index, text: text)
        } else {
          let answer = try await extract(job, index)
          guard generation == epoch, !Task.isCancelled else { return }
          if let reason = authorize(job, job.sources[index]) { throw SereinError.invalid(reason) }
          do { try job.checked(index, extraction: answer) }
          catch { job.unavailable(index, answer.limitation ?? error.localizedDescription) }
        }
      } catch {
        guard generation == epoch, !Task.isCancelled else { return }
        // A transient/provider failure waits for the person; source failures remain visible.
        // Already-fetched evidence is kept, so Continue never repeats that GET.
        if error is ResearchReadFailure {
          job.unavailable(index, error.localizedDescription)
        } else {
          job.state = job.followUp?.phase == .reading && job.sources[index].comparisonOnly == true ? .running : .paused
          job.note = String(AgentPrivacy.redact(error.localizedDescription).prefix(600))
        }
      }
      do { try save(job) } catch { failSaving(error); return }
    }
  }

  private func advanceFollowUp(_ original: ResearchJob, generation: Int) async {
    var job = original
    func authorized() -> Bool {
      guard let reason = authorize(job, nil) else { return true }
      job.state = .paused
      job.note = reason
      do { try save(job) } catch { failSaving(error) }
      return false
    }
    guard authorized(), let phase = job.followUp?.phase else { return }
    do {
      switch phase {
      case .planning:
        if (job.followUp?.planAttempts ?? 0) >= ResearchJob.maxAttempts {
          job.endFollowUp("A useful search plan could not be produced within the retry limit.")
        } else {
          job.followUp?.planAttempts += 1
          try save(job)
          let result = try await plan(job)
          guard generation == epoch, !Task.isCancelled, authorized() else { return }
          try job.plannedFollowUp(result)
        }
      case .searching:
        if let index = job.followUp?.searches.firstIndex(where: { $0.candidates == nil }) {
          if (job.followUp?.searches[index].attempts ?? 0) >= ResearchJob.maxAttempts {
            job.followUp?.searches[index].candidates = []
            job.followUp?.searches[index].searchedAt = Date()
            job.followUp?.searches[index].limitation = "Public search did not succeed within its retry limit."
          } else {
            job.followUp?.searches[index].attempts += 1
            try save(job)
            let results = try await search(job.followUp!.searches[index].query)
            guard generation == epoch, !Task.isCancelled, authorized() else { return }
            var seen = Set(job.sources.map(\.url))
            let accepted = results.filter {
              (try? ResearchJob.publicURL($0.url)) != nil && seen.insert($0.url).inserted
                && authorize(job, .init(url: $0.url, question: "Comparison candidate")) == nil
            }.prefix(ResearchFollowUp.maxCandidates).map {
              ResearchFollowUp.Candidate(url: $0.url, title: String(AgentPrivacy.redact($0.title).prefix(180)))
            }
            job.followUp?.searches[index].candidates = accepted
            job.followUp?.searches[index].searchedAt = Date()
          }
        } else {
          job.followUp?.phase = .selecting
          if job.followUpCandidates.isEmpty { job.endFollowUp("The searches found no new permitted public pages.") }
        }
      case .selecting:
        if (job.followUp?.selectionAttempts ?? 0) >= ResearchJob.maxAttempts {
          job.endFollowUp("A usable page selection could not be produced within the retry limit.")
        } else {
          // Revoked candidates do not reach the selector, even if their titles were saved earlier.
          for index in job.followUp!.searches.indices {
            let candidates = job.followUp?.searches[index].candidates?.filter {
              authorize(job, .init(url: $0.url, question: "Comparison candidate")) == nil
            }
            job.followUp?.searches[index].candidates = candidates
          }
          job.followUp?.selectionAttempts += 1
          try save(job)
          let result = try await select(job)
          guard generation == epoch, !Task.isCancelled, authorized() else { return }
          // Validate before filtering so a model cannot invent a URL, even one that would be denied.
          var updated = job
          try updated.selectedFollowUp(result.urls)
          let permitted = result.urls.filter { authorize(job, .init(url: $0, question: "Comparison candidate")) == nil }
          try job.selectedFollowUp(permitted)
        }
      case .reading: job.compareFollowUp()
      default: return
      }
      job.note = nil
    } catch {
      guard generation == epoch, !Task.isCancelled else { return }
      // Optional follow-up failures retry within persisted limits, then preserve the initial
      // assessment with a visible limitation. Permission failures always pause above.
      job.note = String(AgentPrivacy.redact(error.localizedDescription).prefix(600))
    }
    do { try save(job) } catch { failSaving(error) }
  }

  private func save(_ job: ResearchJob) throws {
    guard let store else { throw SereinError.invalid("The research notebook is not open.") }
    try store.save(job)
    if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
  }
  private func invalidate() { epoch += 1; worker?.cancel(); worker = nil; workerJob = nil }
  private func failSaving(_ error: Error) {
    invalidate()
    problem = "Research stopped because progress could not be saved. " + error.localizedDescription
  }
}
