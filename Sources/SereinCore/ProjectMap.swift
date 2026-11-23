import Foundation

// The projects map: the same projects as the list, sorted into cards. Everything here is pure
// or reads one small file, so SereinChecks can check it. Two of the three rules use only what
// is on this Mac. The third, by purpose, shows areas that the user's agent made when the user
// asked for them (ProjectPurpose.swift); the map itself never asks an agent.

/// One card of the map: a name and its projects in display order.
public struct ProjectArea: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var projectIDs: [String]
  public var id: String { name }
  public init(name: String, projectIDs: [String]) {
    self.name = name
    self.projectIDs = projectIDs
  }
}

/// How the map sorts projects into areas. Git origin and parent folder use only what is on
/// this Mac. Purpose uses the areas that the user's agent made.
public enum ProjectMapBasis: String, CaseIterable, Identifiable, Sendable {
  case gitOrigin = "Git origin"
  case parentFolder = "Parent folder"
  case purpose = "Purpose"
  public var id: String { rawValue }
}

public enum ProjectMap {
  /// The area of a project that has no remote named origin.
  public static let localName = "Local projects"
  public static let areaLimit = 8

  /// The name of the area a project belongs to. `origins` holds the Git origin of each project
  /// that has one (`ProjectOrigin.read`), by project id. A parent folder under `home` is
  /// written with "~", as the list writes the place of a folder. `purposes` holds the area that
  /// the agent gave each project, by project id.
  public static func areaName(
    for project: Project, basis: ProjectMapBasis, origins: [String: String], home: String,
    purposes: [String: String] = [:]
  ) -> String {
    switch basis {
    case .purpose:
      return purposes[project.id] ?? ProjectPurpose.unsortedName
    case .gitOrigin:
      return origins[project.id] ?? localName
    case .parentFolder:
      return HomePath.short(URL(fileURLWithPath: project.path).deletingLastPathComponent().path, home: home)
    }
  }

  /// The cards of the map, in display order. A card holds its projects in the one shared order
  /// of the list (`ProjectOrdering`). At most `limit` cards: the smallest areas merge into
  /// "Other". The card with the liveliest project comes first and "Other" comes last.
  public static func areas(
    projects: [Project], basis: ProjectMapBasis, origins: [String: String], home: String,
    rank: [String: Int], lastActivity: [String: Date], names: [String: String],
    purposeAreas: [ProjectArea] = [], limit: Int = areaLimit
  ) -> [ProjectArea] {
    let purposes = Dictionary(
      purposeAreas.flatMap { area in area.projectIDs.map { ($0, area.name) } },
      uniquingKeysWith: { first, _ in first })
    var members: [String: [String]] = [:]
    for project in projects {
      let name = areaName(for: project, basis: basis, origins: origins, home: home, purposes: purposes)
      members[name, default: []].append(project.id)
    }
    func ordered(_ ids: [String]) -> [String] {
      ProjectOrdering.sorted(ids, rank: rank, lastActivity: lastActivity, names: names)
    }
    // By name first, so that the cap keeps the same areas for the same projects.
    let grouped = members.keys.sorted().map { ProjectArea(name: $0, projectIDs: ordered(members[$0] ?? [])) }
    let capped = ProjectAreaCap.capped(grouped, limit: limit).map { area in
      area.name == ProjectAreaCap.otherName
        ? ProjectArea(name: area.name, projectIDs: ordered(area.projectIDs)) : area
    }
    func lead(_ area: ProjectArea) -> (rank: Int, last: Date) {
      let first = area.projectIDs.first ?? ""
      return (rank[first] ?? 0, lastActivity[first] ?? .distantPast)
    }
    return capped.sorted { a, b in
      let aOther = a.name == ProjectAreaCap.otherName
      let bOther = b.name == ProjectAreaCap.otherName
      if aOther != bOther { return bOther }
      let (ka, kb) = (lead(a), lead(b))
      if ka.rank != kb.rank { return ka.rank > kb.rank }
      if ka.last != kb.last { return ka.last > kb.last }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
  }
}

/// The map keeps at most `limit` areas: the largest stay, the rest merge into "Other".
public enum ProjectAreaCap {
  public static let otherName = "Other"
  public static func capped(_ areas: [ProjectArea], limit: Int = 8) -> [ProjectArea] {
    let nonEmpty = areas.filter { !$0.projectIDs.isEmpty }
    // A limit of one is one card: everything in "Other".
    guard nonEmpty.count > limit, limit > 0 else { return nonEmpty }
    let bySize = nonEmpty.enumerated().sorted {
      $0.element.projectIDs.count != $1.element.projectIDs.count
        ? $0.element.projectIDs.count > $1.element.projectIDs.count : $0.offset < $1.offset
    }
    let keep = Set(bySize.prefix(limit - 1).map(\.offset))
    var kept: [ProjectArea] = []
    var rest: [String] = []
    for (index, area) in nonEmpty.enumerated() {
      if keep.contains(index) && area.name != otherName {
        kept.append(area)
      } else {
        rest += area.projectIDs
      }
    }
    if !rest.isEmpty { kept.append(ProjectArea(name: otherName, projectIDs: rest)) }
    return kept
  }

  /// Greedy masonry: each card goes to the currently shortest column, keeping input order.
  public static func columns(heights: [Double], count: Int, gap: Double = 0) -> [[Int]] {
    let count = max(1, count)
    var columns = Array(repeating: [Int](), count: count)
    var filled = Array(repeating: 0.0, count: count)
    for (index, height) in heights.enumerated() {
      let target = filled.indices.min { filled[$0] != filled[$1] ? filled[$0] < filled[$1] : $0 < $1 } ?? 0
      columns[target].append(index)
      filled[target] += height + gap
    }
    return columns
  }
}

/// Where a repository comes from, as "host/owner". It is read from the repository's own
/// config file; no git program runs and nothing leaves the Mac.
public enum ProjectOrigin {
  /// Retains only host/owner, never URL credentials, query parameters or access tokens.
  public static func group(remote: String) -> String? {
    let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    let url: URL?
    if value.contains("://") {
      url = URL(string: value)
    } else if let colon = value.firstIndex(of: ":"), value[..<colon].contains("@") {
      let host = value[..<colon].split(separator: "@").last ?? ""
      url = URL(string: "ssh://" + host + "/" + value[value.index(after: colon)...])
    } else {
      return nil
    }
    guard let url, ["https", "http", "ssh", "git"].contains(url.scheme ?? ""), let host = url.host,
      !host.isEmpty
    else { return nil }
    let components = url.path.split(separator: "/")
    guard components.count >= 2 else { return host.lowercased() }
    let owner = String(components[0])
    guard owner.range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil else {
      return host.lowercased()
    }
    return host.lowercased() + "/" + owner
  }
  /// A pointer file of a repository (the `.git` file of a worktree, `commondir`). Such a file
  /// is one line. A project folder is not trusted, so a larger file is not read.
  static func pointer(at url: URL) -> String? {
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 4_096 else {
      return nil
    }
    return try? String(contentsOf: url)
  }
  /// True for the header of the section that holds the remote named origin. Git reads the
  /// section name without regard to case, and the name of the remote exactly.
  static func isOriginSection(_ line: String) -> Bool {
    guard line.hasPrefix("["), line.hasSuffix("]") else { return false }
    let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    guard let quote = inner.firstIndex(of: "\"") else { return false }
    return inner[..<quote].trimmingCharacters(in: .whitespaces).lowercased() == "remote"
      && inner[quote...] == "\"origin\""
  }
  /// The origin of the repository at `path`, also for a linked worktree. Nil for a folder that
  /// is no repository, has no remote named origin, or has a config file over 100 KB.
  public static func read(path: String) -> String? {
    let root = URL(fileURLWithPath: path)
    let dotgit = root.appendingPathComponent(".git")
    var config = dotgit.appendingPathComponent("config")
    if let values = try? dotgit.resourceValues(forKeys: [.isRegularFileKey]),
      values.isRegularFile == true,
      let pointer = pointer(at: dotgit), pointer.hasPrefix("gitdir: ")
    {
      let relative = pointer.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
      let gitdir = URL(fileURLWithPath: relative, relativeTo: root).standardizedFileURL
      if let common = Self.pointer(at: gitdir.appendingPathComponent("commondir")) {
        config = URL(
          fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
          relativeTo: gitdir
        ).standardizedFileURL.appendingPathComponent("config")
      } else {
        config = gitdir.appendingPathComponent("config")
      }
    }
    guard let size = (try? config.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
      size < 100_000,
      let text = try? String(contentsOf: config)
    else { return nil }
    var inOrigin = false
    for line in text.components(separatedBy: .newlines) {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        inOrigin = isOriginSection(line)
      } else if inOrigin, let equal = line.firstIndex(of: "="),
        // Git reads the name of a variable without regard to case.
        line[..<equal].trimmingCharacters(in: .whitespaces).lowercased() == "url"
      {
        var value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
          value = String(value.dropFirst().dropLast())
        }
        return group(remote: value)
      }
    }
    return nil
  }
}

/// A path under the home folder written with "~", wherever Serein shows a place. Only a whole
/// folder name matches: "/Users/ann2" is not inside "/Users/ann".
public enum HomePath {
  public static func short(_ path: String, home: String = NSHomeDirectory()) -> String {
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}
