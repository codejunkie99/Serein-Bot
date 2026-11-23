import SereinCore
import SwiftUI

/// The areas that the user's agent made for the Projects map, and the two passes that make
/// them (`ProjectPurpose`). A full arrangement runs only when the user asks for it. The second
/// pass, which puts new projects into the areas that are there, also runs by itself while the
/// map is in view, but only when the user turned that on (`autoKey`).
///
/// What is sent: the name and a short README or manifest excerpt of each project that may
/// reach a provider (`shareableProjects`). Other folders are never sent.
@MainActor final class ProjectPurposeStore: ObservableObject {
  static let shared = ProjectPurposeStore()
  static let path = "projects/areas.json"
  static let previousPath = "projects/areas-previous.json"
  /// "Place new projects by themselves": off unless the user turns it on.
  static let autoKey = "serein.projectsAutoPlace"

  @Published private(set) var areas: [ProjectArea] = []
  /// The areas from before the last full arrangement, for one step back.
  @Published private(set) var previous: [ProjectArea]?
  /// What to tell the user: what was done, or why nothing was.
  @Published private(set) var status = ""
  /// The project files are being read; the request goes out after that.
  @Published private(set) var preparing = false
  private var loaded = false
  private var reading: Task<Void, Never>?
  /// The new projects of the last pass that ran by itself. A pass that failed is not sent again
  /// for the same projects.
  private var attempted = Set<String>()
  /// The user stopped the pass: its end is told as that, not as a fault.
  private var stopped = false

  func ensureLoaded(_ library: Library) {
    guard !loaded else { return }
    loaded = true
    areas = library.load([ProjectArea].self, from: Self.path) ?? []
    previous = library.load([ProjectArea].self, from: Self.previousPath)
  }
  func busy(_ browser: BrowserModel) -> Bool { preparing || browser.intelligenceRunning(.projectGrouping) }
  /// The projects that may be sent, in the order of `order` (the map's own order), others last.
  private func sendable(_ browser: BrowserModel, order: [String]) -> [Project] {
    let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    return browser.shareableProjects.enumerated().sorted {
      (place[$0.element.id] ?? Int.max, $0.offset) < (place[$1.element.id] ?? Int.max, $1.offset)
    }.map(\.element)
  }
  /// The areas of now, without projects that are gone or may no longer be sent. A view calls
  /// `ensureLoaded` when it appears; this only reads, so it is safe in a body.
  func current(_ browser: BrowserModel) -> [ProjectArea] {
    ProjectPurpose.fitted(areas, to: Set(browser.shareableProjects.map(\.id)))
  }
  /// The projects that could be placed and are in no area yet.
  func pending(_ browser: BrowserModel) -> [String] {
    ProjectPurpose.unsorted(browser.shareableProjects.map(\.id), in: current(browser))
  }
  private func ready(_ browser: BrowserModel, agent: AgentModel) -> Bool {
    guard FeaturePolicy.isEnabled(.projectGrouping) else {
      status = "Sorting by purpose is off in Settings › AI apps."
      return false
    }
    guard agent.helperExecutable != nil else {
      status = "Connect Claude Code, Codex or OpenCode to sort by purpose."
      return false
    }
    return !busy(browser)
  }
  /// Asked again just before a request goes out, because reading the files takes time: sorting
  /// is still on, and every project that the request names may still reach a provider. A
  /// project that the user moved to Other folders in the meantime is not sent.
  private func maySend(_ ids: [String], browser: BrowserModel) -> Bool {
    guard FeaturePolicy.isEnabled(.projectGrouping),
      Set(ids).isSubset(of: Set(browser.shareableProjects.map(\.id)))
    else {
      status = "The projects changed before the request went out. Nothing was sent."
      return false
    }
    return true
  }
  /// Reads the briefs away from the main thread, then hands them on.
  private func read(_ projects: [Project], then: @escaping ([ProjectPurpose.Brief]) -> Void) {
    preparing = true
    status = "Reading \(projects.count) project\(projects.count == 1 ? "" : "s")…"
    let folders = projects.map { (id: $0.id, name: $0.name, path: $0.path) }
    reading = Task {
      let briefs = await Task.detached(priority: .userInitiated) {
        folders.map { ProjectPurpose.brief(id: $0.id, name: $0.name, path: $0.path) }
      }.value
      preparing = false
      reading = nil
      guard !Task.isCancelled else { return }
      then(briefs)
    }
  }
  private func keep(_ made: [ProjectArea], library: Library, remember: Bool) throws {
    if remember, !areas.isEmpty {
      try library.save(areas, to: Self.previousPath)
      previous = areas
    }
    try library.save(made, to: Self.path)
    areas = made
  }

  /// The first pass: a full arrangement. The areas of before are kept for one step back.
  func arrange(browser: BrowserModel, agent: AgentModel, order: [String]) {
    ensureLoaded(browser.library)
    guard ready(browser, agent: agent) else { return }
    let all = sendable(browser, order: order)
    let batch = Array(all.prefix(ProjectPurpose.arrangeLimit))
    guard !batch.isEmpty else {
      status = "There are no projects to sort."
      return
    }
    let ids = batch.map(\.id)
    let names = Dictionary(batch.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let before = ProjectPurpose.fitted(areas, to: Set(ids))
    read(batch) { [weak self] briefs in
      // The areas of now are fitted to `ids`, so `ids` are all the projects that this names.
      guard let self, self.maySend(ids, browser: browser) else { return }
      self.status = "Sorting \(ids.count) project\(ids.count == 1 ? "" : "s") with \(agent.helperProvider.name)…"
      browser.runIntelligence(
        .projectGrouping, agent: agent,
        prompt: ProjectPurpose.arrangePrompt(briefs: briefs, current: before, names: names),
        completion: { [weak self] error in
          guard let self else { return }
          if self.stopped {
            self.stopped = false
          } else if let error {
            self.status = "The projects were not sorted: \(error)"
          } else {
            self.status = ""
            // A library with more projects than one arrangement takes: the rest are placed.
            // After this request has ended: it still counts as running here.
            Task { @MainActor [weak self] in self?.assign(browser: browser, agent: agent, order: order) }
          }
        }
      ) { [weak self] text in
        guard let self else { return }
        // The projects can have changed while the agent worked: only an answer for the same
        // ones is kept.
        guard Set(ids).isSubset(of: Set(browser.shareableProjects.map(\.id))) else {
          throw SereinError.invalid("The projects changed while they were sorted. Sort again.")
        }
        try self.keep(ProjectPurpose.arrangement(from: text, ids: ids), library: browser.library, remember: true)
      }
      // The request did not start (no agent, or another one of this kind runs): say nothing.
      if !browser.intelligenceRunning(.projectGrouping) { self.status = "" }
    }
  }

  /// The second pass: the projects that no area holds go into the areas that are there, some
  /// at a time, until none is left. `automatic` is the pass that the map starts by itself.
  func assign(browser: BrowserModel, agent: AgentModel, order: [String], automatic: Bool = false) {
    ensureLoaded(browser.library)
    let all = sendable(browser, order: order)
    let into = ProjectPurpose.fitted(areas, to: Set(all.map(\.id)))
    let waiting = ProjectPurpose.unsorted(all.map(\.id), in: into)
    guard !into.isEmpty, !waiting.isEmpty else { return }
    let ids = Array(waiting.prefix(ProjectPurpose.assignBatch))
    if automatic {
      guard UserDefaults.standard.bool(forKey: Self.autoKey), !agent.running, attempted != Set(ids),
        FeaturePolicy.isEnabled(.projectGrouping), agent.helperExecutable != nil, !busy(browser)
      else { return }
      attempted = Set(ids)
    } else {
      guard ready(browser, agent: agent) else { return }
    }
    let batch = all.filter { ids.contains($0.id) }
    let names = Dictionary(all.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    read(batch) { [weak self] briefs in
      // The request names the new projects and members of the areas: all must still be sendable.
      guard let self, self.maySend(ids + into.flatMap(\.projectIDs), browser: browser) else { return }
      self.status = "Placing \(ids.count) new project\(ids.count == 1 ? "" : "s") with \(agent.helperProvider.name)…"
      browser.runIntelligence(
        .projectGrouping, agent: agent,
        prompt: ProjectPurpose.assignPrompt(briefs: briefs, areas: into, names: names),
        completion: { [weak self] error in
          guard let self else { return }
          if self.stopped {
            self.stopped = false
          } else if let error {
            self.status = "The new projects were not placed: \(error)"
          } else {
            self.status = ""
            Task { @MainActor [weak self] in
              self?.assign(browser: browser, agent: agent, order: order, automatic: automatic)
            }
          }
        }
      ) { [weak self] text in
        guard let self else { return }
        // Placed onto the areas of now: a step back in the meantime must not be undone.
        let base = ProjectPurpose.fitted(self.areas, to: Set(browser.shareableProjects.map(\.id)))
        guard base.map(\.name) == into.map(\.name) else {
          throw SereinError.invalid("The areas changed while the new projects were placed.")
        }
        // A project that is gone or may no longer be sent must not come back into the areas.
        let still = ids.filter { id in !base.contains { $0.projectIDs.contains(id) } }
        guard still == ids, Set(ids).isSubset(of: Set(browser.shareableProjects.map(\.id))) else {
          throw SereinError.invalid("The projects changed while they were placed.")
        }
        try self.keep(ProjectPurpose.assignment(from: text, ids: ids, areas: base), library: browser.library, remember: false)
      }
      if !browser.intelligenceRunning(.projectGrouping) { self.status = "" }
    }
  }

  /// Stops the pass that runs. The areas stay as they are.
  func cancel(browser: BrowserModel) {
    reading?.cancel()
    reading = nil
    preparing = false
    if let request = browser.intelligenceTasks[.projectGrouping] {
      stopped = true
      request.cancel()
    }
    status = "Stopped. The areas are as they were."
  }

  /// One step back: the areas from before the last full arrangement. A second step returns.
  func stepBack(library: Library) {
    ensureLoaded(library)
    guard let back = previous else { return }
    do {
      try library.save(areas, to: Self.previousPath)
      try library.save(back, to: Self.path)
      (areas, previous) = (back, areas)
      status = "The earlier areas are back."
    } catch { status = error.localizedDescription }
  }
}
