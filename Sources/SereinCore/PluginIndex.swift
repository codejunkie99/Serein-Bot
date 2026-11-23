import Foundation

/// The community plugin index (PLUGINS.md P3): a static JSON file in a public repository,
/// reviewed by pull request, holding no executable code — just pointers at GitHub plugin
/// folders, each pinned to one commit where the author has cut a version. Everything here is
/// pure except the fetch, so it is checked in SereinChecks.
public struct PluginIndex: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var author: String
    /// A GitHub link to the plugin's folder; carrying a 40-hex commit pins the install.
    public var link: String
    public var commit: String?
    public var kind: String
    public var license: String?
  }
  public var updated: String?
  public var entries: [Entry]

  static let idPattern = "^[a-z0-9]+([.-][a-z0-9]+)*$"
  static let commitPattern = "^[0-9a-f]{40}$"

  /// The entries worth showing: well-formed, deduplicated by id, capped at 200.
  public static func decode(_ data: Data) -> [Entry] {
    guard let index = try? JSONDecoder().decode(PluginIndex.self, from: data) else { return [] }
    var seen = Set<String>()
    var entries: [Entry] = []
    for var entry in index.entries where entries.count < 200 {
      entry.name = String(entry.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
      entry.description = String(entry.description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
      entry.author = String(entry.author.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
      entry.link = entry.link.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !entry.id.isEmpty, !entry.name.isEmpty, !entry.description.isEmpty, !entry.link.isEmpty,
        entry.id.range(of: idPattern, options: .regularExpression) != nil,
        seen.insert(entry.id).inserted,
        GitHubPluginSource.parse(entry.link) != nil
      else { continue }
      if let commit = entry.commit, !commit.isEmpty {
        guard commit.range(of: commitPattern, options: .regularExpression) != nil else { continue }
      } else {
        entry.commit = nil
      }
      switch entry.kind {
      case "skill", "tools", "remote": break
      default: continue
      }
      entries.append(entry)
    }
    return entries
  }

  /// Whether an entry's link already carries its pinned commit.
  public static func pinned(_ entry: Entry) -> Bool {
    guard let commit = entry.commit else { return false }
    return entry.link.contains(commit)
  }
}
