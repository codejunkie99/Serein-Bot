import Foundation
import SereinCore

/// What the Agents list remembers: each row's place (AgentListOrder), the person's pins, hidden
/// rows and names for tasks, the folded projects, and failures already looked at. Rows go by all
/// their names (`AgentsByProject.Task.keys`), so a mark outlives a session becoming a chat. Written
/// through `setSetting`, so checks and previews never touch the person's list.
@MainActor final class AgentListMemory: ObservableObject {
  static let shared = AgentListMemory()
  private enum Key {
    static let order = "serein.agents.order"
    static let pinned = "serein.agents.pinned"
    static let hidden = "serein.agents.hidden"
    static let titles = "serein.agents.titles"
    static let folded = "serein.agents.foldedProjects"
    static let seenFailures = "serein.agents.seenFailures"
    static let recentsOpen = "serein.agents.recentsOpen"
  }
  /// Read while drawing and changed just after, so it is not published: remembering a row moves nothing.
  private(set) var known: [String]
  @Published private(set) var pinned: [String]
  @Published private(set) var hidden: Set<String>
  @Published private(set) var titles: [String: String]
  @Published private(set) var foldedProjects: Set<String>
  @Published private(set) var seenFailures: Set<String>
  @Published private(set) var recentsOpen: Bool
  /// This launch only: projects showing all their rows, jobs folded, sub-threads shown or hidden by hand.
  @Published var expandedProjects: Set<String> = []
  @Published var foldedJobs: Set<String> = []
  @Published private var subagentsOpen: Set<String> = []
  /// Rows of a long project that have worked this launch. They stay listed after they finish, so a
  /// row does not vanish from under the pointer.
  private var kept: Set<String> = []

  private init() {
    let defaults = UserDefaults.standard
    known = defaults.stringArray(forKey: Key.order) ?? []
    pinned = defaults.stringArray(forKey: Key.pinned) ?? []
    hidden = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
    titles = defaults.dictionary(forKey: Key.titles) as? [String: String] ?? [:]
    foldedProjects = Set(defaults.stringArray(forKey: Key.folded) ?? [])
    seenFailures = Set(defaults.stringArray(forKey: Key.seenFailures) ?? [])
    recentsOpen = defaults.bool(forKey: Key.recentsOpen)
  }

  func toggleRecents() {
    recentsOpen.toggle()
    RelayOrchestrator.setSetting(recentsOpen, forKey: Key.recentsOpen)
  }

  /// Called just after drawing with every row's names, in the order shown.
  func remember(_ rows: [[String]]) {
    let next = AgentListOrder.remembering(rows, known: known) { $0 }
    guard next != known else { return }
    known = next
    RelayOrchestrator.setSetting(next, forKey: Key.order)
  }
  func keep(_ names: [String]) { kept.formUnion(names) }
  func isKept(_ names: [String]) -> Bool { names.contains { kept.contains($0) } }

  func isPinned(_ names: [String]) -> Bool { names.contains { pinned.contains($0) } }
  func togglePin(_ names: [String]) {
    if isPinned(names) {
      pinned.removeAll { names.contains($0) }
    } else if let first = names.first {
      pinned.append(first)
    }
    RelayOrchestrator.setSetting(pinned, forKey: Key.pinned)
  }

  func isHidden(_ names: [String]) -> Bool { names.contains { hidden.contains($0) } }
  func toggleHidden(_ names: [String]) {
    if isHidden(names) {
      hidden.subtract(names)
    } else if let first = names.first {
      hidden.insert(first)
    }
    RelayOrchestrator.setSetting(hidden.sorted(), forKey: Key.hidden)
  }

  func title(_ names: [String]) -> String? { names.lazy.compactMap { self.titles[$0] }.first }
  /// An empty name goes back to the task's own.
  func rename(_ names: [String], to title: String) {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    for name in names { titles[name] = nil }
    if !clean.isEmpty, let first = names.first { titles[first] = String(clean.prefix(120)) }
    RelayOrchestrator.setSetting(titles, forKey: Key.titles)
  }

  func showsSubagents(_ names: [String]) -> Bool { names.contains { subagentsOpen.contains($0) } }
  func toggleSubagents(_ names: [String]) {
    if showsSubagents(names) { subagentsOpen.subtract(names) } else { subagentsOpen.formUnion(names) }
  }

  func toggleFolded(_ project: String) {
    if foldedProjects.contains(project) { foldedProjects.remove(project) } else { foldedProjects.insert(project) }
    RelayOrchestrator.setSetting(foldedProjects.sorted(), forKey: Key.folded)
  }

  func failureSeen(_ names: [String]) -> Bool { names.contains { seenFailures.contains($0) } }
  /// The person opened a failed task: its red word goes.
  func markFailureSeen(_ names: [String]) {
    guard !failureSeen(names), let first = names.first else { return }
    seenFailures.insert(first)
    RelayOrchestrator.setSetting(seenFailures.sorted(), forKey: Key.seenFailures)
  }
}
