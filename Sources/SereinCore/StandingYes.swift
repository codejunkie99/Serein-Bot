import Foundation

/// Every standing yes in one list: a site's routine steps, a project's edits, a connected app's
/// reads, commands on this Mac. Each row reads "where · what" and has Ask again, which takes the
/// yes back. The yeses themselves stay where they are stored (RoutineGrants, ProjectEditApprovals,
/// the connection, LocalExecution); this is the one place that lists them. Pure, so it is checked.
public enum StandingYes {
  public enum Kind: String, CaseIterable, Sendable {
    case site, project, reads, commands
    /// The action half of the row.
    public var action: String {
      switch self {
      case .site: return "Routine steps"
      case .project: return "File edits"
      case .reads: return "Reads"
      case .commands: return "Commands"
      }
    }
  }

  public struct Row: Equatable, Identifiable, Sendable {
    public var kind: Kind
    /// What Ask again takes back: the site, the project's id, the connection's id.
    public var key: String
    /// The app, site or project as the person knows it.
    public var name: String
    /// A stricter rule already wins: the site is set to Ask every step or Never, so this yes
    /// answers nothing while that rule stands.
    public var asksFirst: Bool
    public var id: String { kind.rawValue + ":" + key }
    public var title: String { name + " · " + kind.action }
    public init(kind: Kind, key: String, name: String, asksFirst: Bool = false) {
      self.kind = kind
      self.key = key
      self.name = name
      self.asksFirst = asksFirst
    }
  }

  /// At most this many of each kind; one more drops the oldest, which then asks again.
  public static let cap = 20
  /// The stored lists the cap holds (`GateSettings.update`), each oldest first.
  public static let cappedKeys: Set<String> = [RoutineGrants.sitesKey, ProjectEditApprovals.key]

  /// `value` as it may be stored under `key`: a standing-yes list keeps its newest `cap` entries.
  public static func capped(_ value: Any?, forKey key: String) -> Any? {
    guard cappedKeys.contains(key), let list = value as? [Any], list.count > cap else { return value }
    return Array(list.suffix(cap))
  }

  /// Ask first beats allow: a site's own rule (`SiteRules`) outranks its standing yes.
  public static func asksFirst(site: String, rules: [String: SiteRule]) -> Bool {
    rules.contains { $0.value != .normal && SitePolicy.matches(host: site, site: $0.key) }
  }

  /// The list, newest first inside each kind. `projects` and `reads` pair a stored id with the
  /// name the person knows.
  public static func rows(
    sites: [String], rules: [String: SiteRule], projects: [(id: String, name: String)],
    reads: [(id: String, name: String)], commands: LocalExecution.Mode
  ) -> [Row] {
    var rows: [Row] = sites.suffix(cap).reversed().map {
      Row(kind: .site, key: $0, name: $0, asksFirst: asksFirst(site: $0, rules: rules))
    }
    rows += projects.suffix(cap).reversed().map { Row(kind: .project, key: $0.id, name: $0.name) }
    rows += reads.prefix(cap).map { Row(kind: .reads, key: $0.id, name: $0.name) }
    if commands == .always { rows.append(Row(kind: .commands, key: LocalExecution.key, name: "This Mac")) }
    return rows
  }

  /// Ask again for a row whose yes lives in the gate file. A connection's reads are turned off
  /// by the app (PluginHost), which owns that state. False: not one of these.
  @discardableResult public static func askAgain(_ row: Row, defaults: any SettingsStore = GateSettings.shared) -> Bool {
    switch row.kind {
    case .site: RoutineGrants.revoke(row.key, defaults: defaults)
    case .project: ProjectEditApprovals.revoke(row.key, defaults: defaults)
    case .commands: defaults.set(LocalExecution.Mode.ask.rawValue, forKey: LocalExecution.key)
    case .reads: return false
    }
    return true
  }
}
