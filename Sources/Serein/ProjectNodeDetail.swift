import AppKit
import SereinCore
import SwiftUI

/// Session titles (from history the user agreed to share) and repository facts per folder.
/// `routingEvidence` is what Agent.route() adds to each project entry.
@MainActor final class ProjectInsights: ObservableObject {
  static let shared = ProjectInsights()
  @Published private(set) var all: [String: ProjectInsight] = [:]
  private var loaded = false
  private var refreshing = false

  static func key(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
  }
  func ensureLoaded(_ library: Library) {
    guard !loaded else { return }
    loaded = true
    let cached = ProjectInsight.loadAll(library: library)
    if cached != all { all = cached }
  }
  func insight(_ path: String, library: Library) -> ProjectInsight? {
    ensureLoaded(library)
    return all[Self.key(path)]
  }
  /// One line from Agent.route(): extra evidence fields for a project entry.
  static func routingEvidence(for path: String, library: Library) -> [String: String] {
    shared.insight(path, library: library)?.routingFields ?? [:]
  }
  func setTitles(_ titles: [String], for path: String, library: Library) {
    setTitles([path: titles], library: library)
  }
  /// A discovery pass commits all changed titles together. Repeated identical passes do no
  /// disk work and send no observation update to project cards or the shell.
  func setTitles(_ titlesByPath: [String: [String]], library: Library) {
    ensureLoaded(library)
    var changed: [String: ProjectInsight] = [:]
    for (path, titles) in titlesByPath {
      let key = Self.key(path)
      var item = all[key] ?? ProjectInsight()
      guard item.sessionTitles != titles else { continue }
      item.sessionTitles = titles
      changed[key] = item
    }
    guard !changed.isEmpty else { return }
    var updated = all
    updated.merge(changed) { _, new in new }
    all = updated
    persist(library)
  }
  func setGit(_ git: GitSummary?, for path: String, library: Library) {
    ensureLoaded(library)
    let key = Self.key(path)
    var item = all[key] ?? ProjectInsight()
    guard item.git != git else { return }
    item.git = git
    all[key] = item
    persist(library)
  }
  private func persist(_ library: Library) { try? ProjectInsight.saveAll(all, library: library) }

  /// Reads branch and commit subjects for every project in the background, one at a time.
  func refreshGit(for projects: [Project], library: Library) {
    // Previews seed synthetic branches; their fixture folders are not real repositories.
    guard !refreshing, !CommandLine.arguments.contains("--ui-preview") else { return }
    refreshing = true
    ensureLoaded(library)
    let paths = projects.prefix(150).map(\.path)
    Task {
      var pending: [String: ProjectInsight] = [:]
      for (index, path) in paths.enumerated() {
        let summary = await Task.detached(priority: .utility) {
          GitSummary.read(path: path, timeout: 2)
        }.value
        let key = Self.key(path)
        var item = all[key] ?? ProjectInsight()
        if summary != item.git {
          item.git = summary
          pending[key] = item
        }
        // Preserve progressive updates without rewriting the full cache per repository.
        if (index + 1) % 20 == 0 { applyGit(pending, library: library); pending.removeAll() }
      }
      applyGit(pending, library: library)
      refreshing = false
    }
  }
  private func applyGit(_ changed: [String: ProjectInsight], library: Library) {
    guard !changed.isEmpty else { return }
    var updated = all
    for (key, value) in changed {
      // Discovery can update titles while the Git commands run; merge only Git facts.
      var item = updated[key] ?? ProjectInsight()
      item.git = value.git
      updated[key] = item
    }
    guard updated != all else { return }
    all = updated
    persist(library)
  }
}

/// The one project tile worn everywhere, so a project looks like itself in every view: its
/// initials on a hue derived from its name.
struct ProjectTile: View {
  let name: String
  var size: CGFloat = 16
  @Environment(\.palette) var p
  var body: some View {
    let hue = ProjectMonogram.hue(name)
    Text(ProjectMonogram.initials(name))
      .font(UIStyle.font(max(7, size * 0.42), weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5)
      .foregroundStyle(Color(hue: hue, saturation: p.isDark ? 0.35 : 0.55, brightness: p.isDark ? 0.98 : 0.4))
      .frame(width: size, height: size)
      .background(
        Color(hue: hue, saturation: 0.55, brightness: p.isDark ? 0.62 : 0.85).opacity(0.3),
        in: RoundedRectangle(cornerRadius: max(3, size * 0.28)))
  }
}

/// "3 h"-style stamp for one project: the latest task message or run event.
@MainActor enum ProjectStamp {
  static func date(
    _ projectID: String, activity: ProjectActivityStore, conversations: [Conversation]
  ) -> Date? {
    let fromTasks = conversations.filter { $0.projectID == projectID }.map(\.updatedAt).max()
    guard let event = activity.state(projectID)?.lastEvent else { return fromTasks }
    return max(event, fromTasks ?? .distantPast)
  }
  static func text(
    _ projectID: String, activity: ProjectActivityStore, conversations: [Conversation]
  ) -> String? {
    RelativeTimeShort.text(date(projectID, activity: activity, conversations: conversations))
  }
}
