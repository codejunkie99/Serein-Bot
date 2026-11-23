import Foundation

/// How a folder came to be saved. Older saves have none and are judged by the folder alone.
public enum ProjectSource: String, Codable, Sendable {
  /// The user picked this folder (Add folder, or a conversation import).
  case added
  /// Found in Claude Code or Codex history.
  case history
  /// Found by scanning a folder the user chose.
  case scan
}

/// The user's own call, which always wins over the classifier and is kept across launches.
public enum ProjectPlacement: String, Codable, Sendable {
  case project
  case folder
}

/// What a saved folder looks like on disk. Only `repository` and `manifest` count as projects
/// on their own; everything else is listed under "Other folders" unless the user says otherwise.
public enum ProjectCandidateKind: String, Codable, Sendable, CaseIterable {
  case repository, manifest
  case missing, notFolder, home, standardFolder, temporary, appData, hidden, sereinLibrary
  case chatFolder, plainFolder

  public var isProject: Bool { self == .repository || self == .manifest }

  /// A short reason, shown beside the folder in "Other folders".
  public var label: String {
    switch self {
    case .repository: return "Git repository"
    case .manifest: return "Project files"
    case .missing: return "Folder not found"
    case .notFolder: return "Not a folder"
    case .home: return "Home folder"
    case .standardFolder: return "Standard folder"
    case .temporary: return "Temporary folder"
    case .appData: return "App data"
    case .hidden: return "Hidden folder"
    case .sereinLibrary: return "Serein library"
    case .chatFolder: return "Chat folder"
    case .plainFolder: return "No project files"
    }
  }
}

/// Where the classifier looks: the home folder, temporary roots and Serein's own library.
public struct ProjectCandidateContext: Sendable {
  public var home: String
  public var temporaryRoots: [String]
  public var sereinLibrary: String?
  public init(home: String, temporaryRoots: [String], sereinLibrary: String? = nil) {
    self.home = home
    self.temporaryRoots = temporaryRoots
    self.sereinLibrary = sereinLibrary
  }
  /// This Mac's home, /tmp, /var/folders and $TMPDIR.
  public static func current(
    sereinLibrary: String? = nil, home: String = NSHomeDirectory(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ProjectCandidateContext {
    var roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    if let tmp = environment["TMPDIR"], tmp.hasPrefix("/") { roots.append(tmp) }
    roots.append(NSTemporaryDirectory())
    return ProjectCandidateContext(home: home, temporaryRoots: roots, sereinLibrary: sereinLibrary)
  }
}

/// Decides whether a folder from history, a scan or an older save is a project.
/// Pure apart from one directory listing; never reads file contents.
public enum ProjectCandidate {
  /// Files whose presence at the folder's root marks a project.
  public static let manifests: Set<String> = [
    "package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "setup.py", "setup.cfg",
    "requirements.txt", "Pipfile", "go.mod", "Gemfile", "pom.xml", "build.gradle",
    "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "composer.json", "mix.exs",
    "deno.json", "deno.jsonc", "CMakeLists.txt", "meson.build", "Podfile", "pubspec.yaml",
    "project.godot", "Project.toml", "flake.nix", "stack.yaml", "dune-project", "build.zig",
    "build.sbt", "project.clj", "deps.edn", "Directory.Build.props",
  ]
  /// Extensions of project bundles or descriptors at the root (Xcode, .NET, Unreal, Haskell).
  public static let manifestExtensions: Set<String> = [
    "xcodeproj", "xcworkspace", "csproj", "fsproj", "sln", "uproject", "cabal",
  ]
  static let standardFolders = [
    "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
    "Applications", "Developer", "Code", "Projects", "src",
  ]

  /// True when the root listing alone marks a project.
  public static func hasProjectFiles(_ names: Set<String>) -> Bool {
    if names.contains(".git") || !names.isDisjoint(with: manifests) { return true }
    if names.contains(where: { manifestExtensions.contains(($0 as NSString).pathExtension) }) {
      return true
    }
    return names.contains("Makefile") && names.contains("src")
  }

  /// Folder names that read like a prompt or a pasted link rather than a project name:
  /// "can-you-check-why-co", "https-github-com-owner-repo", "do", "giv", "…".
  public static func looksLikePromptSlug(_ name: String) -> Bool {
    let lower = name.lowercased()
    if lower.isEmpty || lower.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return true }
    for prefix in ["https-", "http-", "www-"] where lower.hasPrefix(prefix) { return true }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    guard name == lower, name.allSatisfy({ allowed.contains($0) }) else { return false }
    let words = name.split(separator: "-")
    if words.count >= 4 { return true }
    return words.count == 1 && name.count <= 3 && name.allSatisfy(\.isLetter)
  }

  static func isDate(_ name: String) -> Bool {
    name.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
  }
  static func clean(_ path: String) -> String {
    var value = URL(fileURLWithPath: path).standardized.path
    while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
    return value
  }
  public static func within(_ path: String, _ root: String) -> Bool {
    let root = clean(root)
    return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
  }

  /// Classifies the folder at `path`. Locations come first (they override project files), then
  /// the folder must exist, be a directory and hold `.git` or a manifest at its root.
  public static func classify(
    path rawPath: String, context: ProjectCandidateContext, fileManager fm: FileManager = .default
  ) -> ProjectCandidateKind {
    let path = clean(rawPath)
    let resolved = clean(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    let home = clean(context.home)
    let homes = Set([home, clean(URL(fileURLWithPath: home).resolvingSymlinksInPath().path)])
    let candidates = Set([path, resolved])

    if candidates.contains(where: { homes.contains($0) }) || path == "/" { return .home }
    if let library = context.sereinLibrary,
      candidates.contains(where: { within($0, library) })
    {
      return .sereinLibrary
    }
    for root in context.temporaryRoots where candidates.contains(where: { within($0, root) }) {
      return .temporary
    }
    for base in homes {
      for folder in standardFolders where candidates.contains(base + "/" + folder) {
        return .standardFolder
      }
      let icloud = base + "/Library/Mobile Documents"
      if candidates.contains(where: { within($0, base + "/Library") && !within($0, icloud) }) {
        return .appData
      }
    }
    let components = path.split(separator: "/")
    if components.contains(where: { $0.hasPrefix(".") }) { return .hidden }

    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
    guard isDirectory.boolValue else { return .notFolder }
    let names = Set((try? fm.contentsOfDirectory(atPath: path)) ?? [])
    if names.contains(".git") { return .repository }
    if hasProjectFiles(names) { return .manifest }
    let name = (path as NSString).lastPathComponent
    let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    if looksLikePromptSlug(name) || isDate(parent) { return .chatFolder }
    return .plainFolder
  }
}

/// Splits saved folders into projects and "Other folders" without changing or deleting any.
public enum ProjectShelf {
  /// The user's placement wins; folders the user added stay projects; the rest follow the
  /// classifier. An unclassified folder stays a project so nothing vanishes before a check.
  public static func isProject(_ project: Project, kind: ProjectCandidateKind?) -> Bool {
    switch project.placement {
    case .project?: return true
    case .folder?: return false
    case nil:
      if project.source == .added { return true }
      return kind?.isProject ?? true
    }
  }
  /// A quiet note for a project kept for a reason other than its files, e.g. "Added by you".
  public static func note(_ project: Project, kind: ProjectCandidateKind?) -> String? {
    guard isProject(project, kind: kind), kind?.isProject != true else { return nil }
    return project.placement == .project ? "Made a project" : "Added by you"
  }
  /// Whether a folder's name, path or files may go to a provider (grouping, routing, dev-server
  /// facts). Only listed projects, and never one still waiting for a verdict unless the user
  /// added it: names from history can carry prompt text or pasted links.
  public static func isShareable(_ project: Project, kind: ProjectCandidateKind?) -> Bool {
    switch project.placement {
    case .project?: return true
    case .folder?: return false
    case nil: return project.source == .added || kind?.isProject == true
    }
  }
  public static func shareable(_ projects: [Project], kinds: [String: ProjectCandidateKind])
    -> [Project]
  {
    projects.filter { isShareable($0, kind: kinds[$0.id]) }
  }
  public static func partition(
    _ projects: [Project], kinds: [String: ProjectCandidateKind]
  ) -> (projects: [Project], folders: [Project]) {
    var listed: [Project] = []
    var folders: [Project] = []
    for project in projects {
      if isProject(project, kind: kinds[project.id]) {
        listed.append(project)
      } else {
        folders.append(project)
      }
    }
    return (listed, folders)
  }
}

/// The list's three activity sections.
public enum ProjectRecencySection: String, CaseIterable, Sendable {
  case now = "Working now"
  case week = "This week"
  case earlier = "Earlier"

  public static func of(
    running: Bool, needsYou: Bool, lastActivity: Date?, now: Date = Date()
  ) -> ProjectRecencySection {
    if running || needsYou { return .now }
    if let lastActivity, now.timeIntervalSince(lastActivity) < 7 * 86_400 { return .week }
    return .earlier
  }
}
