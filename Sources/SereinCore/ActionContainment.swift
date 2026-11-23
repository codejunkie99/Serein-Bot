import Foundation

/// Clicks and typing start off. A value already stored as on is turned off once.
/// After that, a choice the user makes again is kept.
public enum ActionClickDefault {
  public static let key = "serein.allowActions"
  public static let migratedKey = "serein.allowActions.reset"

  public struct Step: Equatable, Sendable {
    public var value: Bool
    /// Write false over a stored true. Once.
    public var writeOff: Bool
    public var markReset: Bool
  }

  /// `stored` true and `migrated` false comes back off.
  /// Removing the migrated check turns a later choice off again.
  public static func plan(stored: Bool?, migrated: Bool) -> Step {
    if migrated { return Step(value: stored ?? false, writeOff: false, markReset: false) }
    if stored == true { return Step(value: false, writeOff: true, markReset: true) }
    return Step(value: false, writeOff: false, markReset: true)
  }

  @discardableResult
  public static func apply(_ defaults: any SettingsStore = GateSettings.shared) -> Step {
    let step = plan(stored: defaults.object(forKey: key) as? Bool, migrated: defaults.bool(forKey: migratedKey))
    if step.writeOff { defaults.set(false, forKey: key) }
    if step.markReset { defaults.set(true, forKey: migratedKey) }
    return step
  }
}

/// Paired outside apps lose a stored click grant once. A grant the user turns on later stays.
public enum PairingGrantReset {
  public static let migratedKey = "serein.pairingActions.reset"

  /// True when this launch should turn clicks off on a pairing that still has them.
  public static func shouldClear(allowActions: Bool, migrated: Bool) -> Bool {
    !migrated && allowActions
  }

  public static func cleared(_ grant: AgentGrant) -> AgentGrant {
    var copy = grant
    copy.allowActions = false
    return copy
  }

  /// The reset, once per install: clears the stored pairings unless `defaults` marks it done,
  /// then marks it. Every caller goes through here. Returns the ids changed.
  @discardableResult
  public static func migrateOnce(root: URL, defaults: UserDefaults) -> Set<String> {
    guard !defaults.bool(forKey: migratedKey) else { return [] }
    let changed = Set(clearStored(root: root))
    defaults.set(true, forKey: migratedKey)
    return changed
  }

  /// Turns clicks off on every stored pairing that still has them. Returns the ids changed.
  static func clearStored(root: URL) -> [String] {
    let folder = AgentAccess.grants(root: root)
    var changed: [String] = []
    for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    where file.pathExtension == "json" {
      guard let data = try? Data(contentsOf: file),
        let grant = try? JSONDecoder().decode(AgentGrant.self, from: data),
        shouldClear(allowActions: grant.allowActions, migrated: false)
      else { continue }
      if (try? cleared(grant).write(to: file)) != nil { changed.append(grant.id) }
    }
    return changed
  }
}
