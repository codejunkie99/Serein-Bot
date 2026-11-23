import Foundation
import SereinCore

/// Projects versus "Other folders": the classifier's verdict per saved folder, plus the user's
/// own choice, which is saved with the project and always wins. Nothing is ever deleted here.
extension BrowserModel {
  /// Real projects, in saved order; the Projects list shows these.
  var listedProjects: [Project] { ProjectShelf.partition(projects, kinds: projectKinds).projects }
  /// Projects whose names, paths and files may reach a provider: listed ones with a verdict
  /// (or added by the user). Other folders never do. Routing and dev-server facts use it.
  var shareableProjects: [Project] { ProjectShelf.shareable(projects, kinds: projectKinds) }
  /// Saved folders that do not look like projects (chat folders, temp, home, missing…).
  var otherFolders: [Project] { ProjectShelf.partition(projects, kinds: projectKinds).folders }

  /// Where to look. Previews judge their synthetic fixture home; checks whose library lives in
  /// a temporary folder keep their temporary fixtures.
  var projectCandidateContext: ProjectCandidateContext {
    let root = library.root.resolvingSymlinksInPath().path
    if CommandLine.arguments.contains("--ui-preview") {
      return ProjectCandidateContext(
        home: root + "/Fixtures/home", temporaryRoots: [], sereinLibrary: root + "/Anywhere")
    }
    var context = ProjectCandidateContext.current(sereinLibrary: root)
    if context.temporaryRoots.contains(where: { ProjectCandidate.within(root, $0) }) {
      context.temporaryRoots = []
      context.sereinLibrary = root + "/Anywhere"
    }
    return context
  }
  /// Classifies every saved folder off the main thread (one directory listing each) and caches
  /// the verdicts in projects/kinds.json, so the next launch draws the right split at once.
  func refreshProjectKinds() {
    if projectKinds.isEmpty,
      let cached = library.load([String: ProjectCandidateKind].self, from: "projects/kinds.json")
    {
      let ids = Set(projects.map(\.id))
      projectKinds = cached.filter { ids.contains($0.key) }
    }
    let context = projectCandidateContext
    let captured = projects
    kindsTask?.cancel()
    kindsTask = Task {
      let kinds = await Task.detached(priority: .utility) {
        ProjectAutoDiscovery.kinds(captured, context: context)
      }.value
      guard !Task.isCancelled, captured.map(\.id) == projects.map(\.id) else { return }
      if kinds != projectKinds { projectKinds = kinds }
      try? library.save(kinds, to: "projects/kinds.json")
    }
  }
  /// The same, synchronously; previews and checks use it for a deterministic first frame.
  func refreshProjectKindsNow() {
    let kinds = ProjectAutoDiscovery.kinds(projects, context: projectCandidateContext)
    if kinds != projectKinds { projectKinds = kinds }
  }
  /// Saves folders found in agent history with their verdicts, so they never flash in the
  /// wrong place. Returns how many of them are projects.
  @discardableResult
  func addDiscovered(_ result: ProjectDiscoveryResult) -> Int {
    // A folder removed while the scan ran stays removed.
    let known = Set(projects.map { ProjectAutoDiscovery.key($0.path) })
      .union(SessionDiscoveryModel.shared.dismissed)
    // Serein's own Anywhere folder shows in its own agents' history: never saved as a project.
    let fresh = result.added.filter { !known.contains(ProjectAutoDiscovery.key($0.path)) && !insideSereinData($0.path) }
    guard !fresh.isEmpty else { return 0 }
    for project in fresh { projectKinds[project.id] = result.kinds[project.id] }
    projects += fresh
    saveProjects()
    warnIfHoldsSereinData(fresh.map(\.path))
    return fresh.filter { result.kinds[$0.id]?.isProject == true }.count
  }
  /// Removes a saved folder from Serein (never from disk) and keeps automatic discovery from
  /// bringing it back.
  func removeProject(_ id: String) {
    guard let project = projects.first(where: { $0.id == id }) else { return }
    SessionDiscoveryModel.shared.remember(removed: project.path)
    projects.removeAll { $0.id == id }
    saveProjects()
  }
  func kind(of project: Project) -> ProjectCandidateKind? { projectKinds[project.id] }

  /// "Make project" / "Move to Other folders". Saved with the project, so it persists.
  func setPlacement(_ placement: ProjectPlacement?, for projectID: String) {
    guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
    projects[index].placement = placement
    saveProjects()
  }
}
