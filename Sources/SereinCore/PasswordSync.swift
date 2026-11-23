import Foundation
import Security

/// Pure decisions and Keychain query construction for the optional iCloud Keychain sync of saved
/// passwords. Nothing here touches the Keychain, so it can be checked without side effects.
public enum PasswordSync {
  /// Where an entry lives. Device-only entries sit in the login keychain with a ThisDeviceOnly
  /// class; synchronized entries must sit in the data-protection keychain, which macOS only grants
  /// to a signed app with a keychain-access-groups entitlement.
  public enum Store: String, Equatable, Sendable { case login, dataProtection }

  public struct Placement: Equatable, Sendable {
    public var store: Store
    public var synchronizable: Bool
    public static let deviceOnly = Placement(store: .login, synchronizable: false)
    public static let synced = Placement(store: .dataProtection, synchronizable: true)
    public init(store: Store, synchronizable: Bool) {
      self.store = store
      self.synchronizable = synchronizable
    }
  }

  public enum Availability: Equatable, Sendable {
    case available
    case unavailable(String)
    public var isAvailable: Bool { self == .available }
  }

  public static let unsignedExplanation =
    "Needs a signed build of Serein; this build keeps passwords on this Mac."

  /// Maps the status of the throwaway add used by the capability probe.
  public static func classify(probeStatus: OSStatus) -> Availability {
    switch probeStatus {
    case errSecSuccess, errSecDuplicateItem: return .available
    case errSecMissingEntitlement, errSecNotAvailable, errSecParam, errSecAuthFailed,
      errSecInteractionNotAllowed, errSecNoSuchKeychain:
      return .unavailable(unsignedExplanation)
    default:
      return .unavailable(unsignedExplanation + " (Keychain status \(probeStatus).)")
    }
  }

  public enum OffChoice: Equatable, Sendable {
    /// Copy each entry back to this Mac only and delete the synchronized item, which iCloud
    /// Keychain then deletes from the other devices too.
    case removeFromOtherDevices
    /// Leave existing synchronized entries alone, so other devices keep them; only entries saved
    /// from now on stay on this Mac.
    case leaveSynced
  }

  public enum Decision: Equatable, Sendable {
    case unavailable(String)
    case noChange
    /// Flip the setting; no entries need to move.
    case apply
    case confirmEnable(entryCount: Int)
    case confirmDisable(entryCount: Int)
  }

  public static func decide(
    current: Bool, desired: Bool, availability: Availability, entriesToMove: Int
  ) -> Decision {
    if current == desired { return .noChange }
    if desired {
      if case .unavailable(let why) = availability { return .unavailable(why) }
      return entriesToMove > 0 ? .confirmEnable(entryCount: entriesToMove) : .apply
    }
    // Turning off without a reachable synchronized store has nothing to migrate.
    guard availability.isAvailable, entriesToMove > 0 else { return .apply }
    return .confirmDisable(entryCount: entriesToMove)
  }

  public struct Step: Equatable, Sendable {
    public var id: String
    public var from: Placement
    public var to: Placement
  }

  public static func plan(
    entries: [(id: String, placement: Placement)], enabling: Bool,
    offChoice: OffChoice = .removeFromOtherDevices
  ) -> [Step] {
    if !enabling && offChoice == .leaveSynced { return [] }
    let target: Placement = enabling ? .synced : .deviceOnly
    return entries.filter { $0.placement != target }.map {
      Step(id: $0.id, from: $0.placement, to: target)
    }
  }

  /// Where a brand-new entry goes.
  public static func placementForNewEntry(syncOn: Bool, availability: Availability) -> Placement {
    syncOn && availability.isAvailable ? .synced : .deviceOnly
  }

  /// Stores to search. Synchronized entries stay reachable even when the setting is off.
  public static func searchStores(availability: Availability) -> [Store] {
    availability.isAvailable ? [.login, .dataProtection] : [.login]
  }

  public static func accessibility(for placement: Placement) -> CFString {
    // ThisDeviceOnly classes cannot sync.
    placement.synchronizable
      ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  }

  // MARK: Queries

  private static func base(service: String, store: Store) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      // Find the entry whether or not it is synchronized.
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
    if store == .dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
    return q
  }

  public static func listQuery(service: String, store: Store) -> [String: Any] {
    var q = base(service: service, store: store)
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    return q
  }

  public static func itemQuery(service: String, account: String, store: Store) -> [String: Any] {
    var q = base(service: service, store: store)
    q[kSecAttrAccount as String] = account
    return q
  }

  public static func readQuery(service: String, account: String, store: Store) -> [String: Any] {
    var q = itemQuery(service: service, account: account, store: store)
    q[kSecReturnData as String] = true
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    return q
  }

  public static func deleteQuery(service: String, account: String, store: Store) -> [String: Any] {
    itemQuery(service: service, account: account, store: store)
  }

  public static func addQuery(
    service: String, account: String, secret: Data, generic: Data, label: String,
    placement: Placement
  ) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: secret,
      kSecAttrGeneric as String: generic,
      kSecAttrLabel as String: label,
      kSecAttrAccessible as String: accessibility(for: placement),
      kSecAttrSynchronizable as String: placement.synchronizable,
    ]
    if placement.store == .dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
    return q
  }

  /// The throwaway item the capability probe adds and immediately deletes. It is a
  /// data-protection item (which needs the same entitlement as a synchronizable one) that never
  /// syncs, so probing sends nothing to iCloud Keychain or the user's other devices.
  public static func probeAddQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data("probe".utf8),
      kSecAttrLabel as String: "Serein capability probe",
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  /// Deletes exactly the probe item (never a synchronizable one).
  public static func probeDeleteQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  /// Probe outcomes that hold for this build and may be remembered across launches. Anything
  /// else (a locked keychain, a busy daemon) is transient and is probed again next time.
  public static func isDefinitive(probeStatus: OSStatus, deleted: Bool) -> Bool {
    (probeStatus == errSecSuccess && deleted) || probeStatus == errSecMissingEntitlement
  }

  /// Migration found an entry with the same id already at the target.
  public enum DuplicateResolution: Equatable, Sendable {
    /// Overwrite the target with the source's secret, then delete the source.
    case updateTarget
    /// The target is newer: keep it and delete the source.
    case keepTarget
  }
  /// Keeps whichever copy changed last; without dates the source (the copy in use) wins.
  public static func resolveDuplicate(sourceModified: Date?, targetModified: Date?)
    -> DuplicateResolution
  {
    guard let sourceModified, let targetModified else { return .updateTarget }
    return targetModified > sourceModified ? .keepTarget : .updateTarget
  }
}
