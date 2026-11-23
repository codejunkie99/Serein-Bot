import SereinCore
import SwiftUI
import Combine

/// Reads the run log (Library.runs) a few seconds apart and exposes per-project markers.
@MainActor final class ProjectActivityStore: ObservableObject {
  static let shared = ProjectActivityStore()
  @Published private(set) var states: [String: ProjectActivityState] = [:]
  private var loop: Task<Void, Never>?
  private var localStates: [String: ProjectActivityState] = [:]
  private weak var browser: BrowserModel?
  private var projectsByPath: [String: String] = [:]
  private var subscriptions = Set<AnyCancellable>()
  func attach(_ browser: BrowserModel) {
    self.browser = browser
    subscriptions.removeAll()
    ExternalSessionStore.shared.$sessions.sink { [weak self] sessions in
      self?.merge(sessions)
    }.store(in: &subscriptions)
    browser.$projects.sink { [weak self] projects in
      self?.projectsByPath = Dictionary(projects.map { (ProjectInsights.key($0.path), $0.id) }, uniquingKeysWith: { first, _ in first })
      self?.merge(ExternalSessionStore.shared.sessions)
    }.store(in: &subscriptions)
    start(library: browser.library)
  }

  func start(library: Library) {
    guard loop == nil else { return }
    loop = Task.detached(priority: .utility) { [weak self] in
      var reader = RunLogSnapshotReader(library: library)
      var revision: UInt64?
      var day: Date?
      var timeZone: TimeZone?
      while !Task.isCancelled {
        guard !Task.isCancelled, let self else { return }
        let runs = reader.snapshot()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Midnight and a timezone change expire "Done today" even without a log append.
        if revision != reader.revision || day != today || timeZone != calendar.timeZone {
          let states = ProjectActivity.states(runs: runs, calendar: calendar)
          guard !Task.isCancelled else { return }
          await self.update(states)
          revision = reader.revision
          day = today
          timeZone = calendar.timeZone
        }
        do { try await Task.sleep(nanoseconds: 4_000_000_000) }
        catch { return }
      }
    }
  }
  /// Reads the run log once, now. Previews use it so markers are drawn on the first frame.
  func prime(library: Library) { update(ProjectActivity.states(runs: library.runs())) }
  private func update(_ current: [String: ProjectActivityState]) {
    localStates = current
    merge(ExternalSessionStore.shared.sessions)
  }
  private func merge(_ external: [ExternalSession]) {
    var current = localStates
    if browser != nil {
      for session in external where session.state != .open {
        guard let path = session.cwd, let id = projectsByPath[path] else { continue }
        var state = current[id] ?? ProjectActivityState()
        state.running = state.running || session.state == .running
        state.needsYou = state.needsYou || session.state == .needsUser
        state.lastEvent = max(state.lastEvent ?? .distantPast, session.updatedAt)
        current[id] = state
      }
    }
    if current != states { states = current }
  }
  func state(_ projectID: String) -> ProjectActivityState? { states[projectID] }
  /// Stable sort: needs you, running, done today, then the original order.
  func sorted(_ projects: [Project]) -> [Project] {
    projects.enumerated().sorted {
      let a = ProjectActivity.rank(states[$0.element.id])
      let b = ProjectActivity.rank(states[$1.element.id])
      return a != b ? a > b : $0.offset < $1.offset
    }.map(\.element)
  }
}

/// Running ring, needs-you dot, or "Done today". Each has a shape and a word, never colour alone.
struct ProjectActivityBadge: View {
  var projectID: String
  var library: Library
  var compact = true
  @ObservedObject private var store = ProjectActivityStore.shared
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.sereinReducedEffects) var previewReducedEffects

  var body: some View {
    Group {
      if let state = store.state(projectID) {
        if state.needsYou {
          marker(Circle().fill(p.accent).frame(width: 8, height: 8), "Needs you")
        } else if state.running {
          marker(runningRing, "Running")
        } else if state.doneToday {
          HStack(spacing: 3) {
            InterfaceIcon(systemName: "checkmark")
            if !compact { Text("Done today") }
          }.font(UIStyle.micro).foregroundStyle(p.secondary)
            .accessibilityLabel("Done today").help("Done today")
        }
      }
    }.onAppear { ProjectActivityStore.shared.start(library: library) }
  }
  /// Most of a ring, turning once every 1.1 seconds; still with Reduce Motion.
  @ViewBuilder var runningRing: some View {
    if reduceMotion || previewReducedEffects {
      Circle().trim(from: 0, to: 0.72).stroke(p.accent, lineWidth: 1.6).frame(width: 11, height: 11)
    } else {
      // Turned by Core Animation, so SwiftUI does not redraw the ring for each frame. A point
      // wider each way than the ring: the stroke is centred on its circle.
      TurningArc(
        color: p.accent, diameter: 11, fraction: 0.72, lineWidth: 1.6, lineCap: .butt, period: 1.1
      ).frame(width: 13, height: 13).frame(width: 11, height: 11)
    }
  }
  func marker<S: View>(_ shape: S, _ word: String) -> some View {
    HStack(spacing: 4) {
      shape
      if !compact { Text(word).font(UIStyle.micro).foregroundStyle(p.secondary) }
    }.accessibilityElement(children: .ignore).accessibilityLabel(word).help(word)
  }
}
