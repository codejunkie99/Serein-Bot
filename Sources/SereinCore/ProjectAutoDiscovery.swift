import Foundation

/// What one pass over local agent history found: folders not saved yet (projects and other
/// folders alike) and how each looks on disk.
public struct ProjectDiscoveryResult {
  public var added: [Project]
  public var kinds: [String: ProjectCandidateKind]
  public var discovered: [DiscoveredProject]
  public init(added: [Project], kinds: [String: ProjectCandidateKind], discovered: [DiscoveredProject]) {
    self.added = added
    self.kinds = kinds
    self.discovered = discovered
  }
  /// How many of the added folders count as projects on their own.
  public var projectCount: Int { added.filter { kinds[$0.id]?.isProject == true }.count }
}

/// Saves every folder from Claude Code and Codex history automatically. The classifier then
/// splits them into projects and "Other folders"; nothing needs the user's action, and a folder
/// the user removed stays out.
public enum ProjectAutoDiscovery {
  /// The same key used for saved projects: symlinks resolved, path standardised.
  public static func key(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
  }

  /// History folders that are neither saved nor removed by the user, as new history saves.
  public static func newProjects(
    _ discovered: [DiscoveredProject], existing: [Project], removed: Set<String>
  ) -> [Project] {
    var known = Set(existing.map { key($0.path) }).union(removed.map(key))
    var added: [Project] = []
    for item in discovered {
      let path = key(item.path)
      guard !known.contains(path) else { continue }
      known.insert(path)
      added.append(Project(name: item.name, path: item.path, source: .history))
    }
    return added
  }

  /// Classifies each project's folder (one directory listing each). Run off the main thread.
  public static func kinds(
    _ projects: [Project], context: ProjectCandidateContext, fileManager: FileManager = .default
  ) -> [String: ProjectCandidateKind] {
    var kinds: [String: ProjectCandidateKind] = [:]
    for project in projects {
      guard !Task.isCancelled else { return [:] }
      kinds[project.id] = ProjectCandidate.classify(
        path: project.path, context: context, fileManager: fileManager)
    }
    return kinds
  }

  /// One full pass: read both history roots, keep folders not yet saved, classify them.
  public static func run(
    claudeRoot: URL, codexRoot: URL, home: String = NSHomeDirectory(), existing: [Project],
    removed: Set<String>, context: ProjectCandidateContext
  ) -> ProjectDiscoveryResult {
    let discovered = SessionIndex.discover(claudeRoot: claudeRoot, codexRoot: codexRoot, home: home)
    let added = newProjects(discovered, existing: existing, removed: removed)
    return ProjectDiscoveryResult(
      added: added, kinds: kinds(added, context: context), discovered: discovered)
  }
}
