import AppKit
import Security
import SereinCore
import SwiftUI

/// iCloud Keychain sync for saved passwords. Query construction and migration decisions live in
/// SereinCore (`PasswordSync`); this file performs the Keychain calls and shows the setting.
/// Synchronizable items need a signed build with a keychain-access-groups entitlement, so every
/// path first asks the capability probe and otherwise keeps passwords on this Mac.
extension PasswordVault {
  static let syncDefaultsKey = "serein.passwords.syncICloud"

  /// Probes when nothing is known yet. Only the settings row calls this, so a launch never
  /// probes unless the user opens it; a definitive result is remembered for this build.
  var syncAvailability: PasswordSync.Availability {
    if let known = knownSyncAvailability { return known }
    let (value, definitive) = probeSync()
    if definitive {
      cachedSyncAvailability = value
      UserDefaults.standard.set(value.isAvailable, forKey: Self.probeKey)
    }
    return value
  }

  /// What is known without probing: this session's result or a remembered one for this build.
  private var knownSyncAvailability: PasswordSync.Availability? {
    if let cached = cachedSyncAvailability { return cached }
    guard let stored = UserDefaults.standard.object(forKey: Self.probeKey) as? Bool else {
      return nil
    }
    let value: PasswordSync.Availability =
      stored ? .available : .unavailable(PasswordSync.unsignedExplanation)
    cachedSyncAvailability = value
    return value
  }

  /// One remembered probe result per build (the executable's path and modification date).
  private static var probeKey: String {
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let date =
      ((try? FileManager.default.attributesOfItem(atPath: executable.path))?[.modificationDate]
        as? Date)?.timeIntervalSince1970 ?? 0
    let path = executable.path.replacingOccurrences(of: ".", with: "_")
    return "serein.passwords.syncProbe:" + path + ":" + String(Int(date))
  }

  /// Adds and deletes a throwaway non-synchronizable data-protection item. Skipped in previews.
  private func probeSync() -> (PasswordSync.Availability, definitive: Bool) {
    if CommandLine.arguments.contains("--ui-preview") {
      return (.unavailable(PasswordSync.unsignedExplanation), false)
    }
    let probeService = service + ".syncprobe"
    let account = "probe-" + UUID().uuidString
    let status = SecItemAdd(
      PasswordSync.probeAddQuery(service: probeService, account: account) as CFDictionary, nil)
    var deleted = false
    if status == errSecSuccess {
      let query = PasswordSync.probeDeleteQuery(service: probeService, account: account)
      deleted = SecItemDelete(query as CFDictionary) == errSecSuccess
      if !deleted { deleted = SecItemDelete(query as CFDictionary) == errSecSuccess }
    }
    var value = PasswordSync.classify(probeStatus: status)
    if status == errSecSuccess && !deleted {
      value = .unavailable("The Keychain check could not clean up after itself. Try again.")
    }
    return (value, PasswordSync.isDefinitive(probeStatus: status, deleted: deleted))
  }

  /// Keychain reads never probe; synced entries are searched once sync is known to work.
  private var stores: [PasswordSync.Store] {
    PasswordSync.searchStores(
      availability: knownSyncAvailability ?? .unavailable(PasswordSync.unsignedExplanation))
  }

  /// Every entry row with the store it was found in. Login-store errors surface; a data-protection
  /// store that cannot be read is treated as empty.
  private func rowsByStore() -> (rows: [(PasswordSync.Store, [String: Any])], status: OSStatus) {
    var all: [(PasswordSync.Store, [String: Any])] = []
    for store in stores {
      var result: CFTypeRef?
      let status = SecItemCopyMatching(
        PasswordSync.listQuery(service: service, store: store) as CFDictionary, &result)
      if status == errSecItemNotFound { continue }
      guard status == errSecSuccess else {
        if store == .login { return ([], status) }
        continue
      }
      for row in result as? [[String: Any]] ?? [] { all.append((store, row)) }
    }
    return (all, errSecSuccess)
  }

  func keychainRows() -> ([[String: Any]], OSStatus) {
    let found = rowsByStore()
    return (found.rows.map(\.1), found.status)
  }

  func entryPlacements() -> [(id: String, placement: PasswordSync.Placement)] {
    rowsByStore().rows.compactMap { store, row in
      guard let account = row[kSecAttrAccount as String] as? String else { return nil }
      return (account, store == .dataProtection ? .synced : .deviceOnly)
    }
  }

  func updateExisting(id: String, secret: Data, generic: Data, label: String) -> OSStatus {
    let values: [String: Any] = [
      kSecValueData as String: secret, kSecAttrGeneric as String: generic,
      kSecAttrLabel as String: label,
    ]
    var last = errSecItemNotFound
    for store in stores {
      let status = SecItemUpdate(
        PasswordSync.itemQuery(service: service, account: id, store: store) as CFDictionary,
        values as CFDictionary)
      if status != errSecItemNotFound { last = status }
      if status == errSecSuccess { break }
    }
    return last
  }

  func addNew(id: String, secret: Data, generic: Data, label: String) -> OSStatus {
    let placement = PasswordSync.placementForNewEntry(
      syncOn: syncEnabled,
      availability: knownSyncAvailability ?? .unavailable(PasswordSync.unsignedExplanation))
    return SecItemAdd(
      PasswordSync.addQuery(
        service: service, account: id, secret: secret, generic: generic, label: label,
        placement: placement) as CFDictionary, nil)
  }

  func readSecret(id: String) -> Data? {
    for store in stores {
      var result: CFTypeRef?
      let status = SecItemCopyMatching(
        PasswordSync.readQuery(service: service, account: id, store: store) as CFDictionary,
        &result)
      if status == errSecSuccess, let row = result as? [String: Any],
        let data = row[kSecValueData as String] as? Data
      {
        return data
      }
    }
    return nil
  }

  func deleteEverywhere(id: String) -> Bool {
    var deleted = false
    for store in stores {
      let status = SecItemDelete(
        PasswordSync.deleteQuery(service: service, account: id, store: store) as CFDictionary)
      if status == errSecSuccess { deleted = true }
    }
    return deleted
  }

  struct MigrationResult { var moved = 0; var failed = 0 }

  /// Copies each entry to its new placement, then deletes the original. A failed copy leaves the
  /// original untouched.
  func migrate(_ steps: [PasswordSync.Step]) -> MigrationResult {
    var result = MigrationResult()
    for step in steps {
      var found: CFTypeRef?
      guard
        SecItemCopyMatching(
          PasswordSync.readQuery(service: service, account: step.id, store: step.from.store)
            as CFDictionary, &found) == errSecSuccess,
        let row = found as? [String: Any], let secret = row[kSecValueData as String] as? Data,
        let generic = row[kSecAttrGeneric as String] as? Data
      else {
        result.failed += 1
        continue
      }
      let label = row[kSecAttrLabel as String] as? String ?? ""
      let added = SecItemAdd(
        PasswordSync.addQuery(
          service: service, account: step.id, secret: secret, generic: generic, label: label,
          placement: step.to) as CFDictionary, nil)
      if added == errSecDuplicateItem {
        // Both stores hold this id (an earlier move stopped half way): keep the newer copy.
        guard resolveDuplicate(step, source: row, secret: secret, generic: generic, label: label)
        else {
          result.failed += 1
          continue
        }
      } else if added != errSecSuccess {
        result.failed += 1
        continue
      }
      let removed = SecItemDelete(
        PasswordSync.deleteQuery(service: service, account: step.id, store: step.from.store)
          as CFDictionary)
      if removed == errSecSuccess { result.moved += 1 } else { result.failed += 1 }
    }
    return result
  }

  /// True when the target now holds the newer secret, so the source may be deleted.
  private func resolveDuplicate(
    _ step: PasswordSync.Step, source: [String: Any], secret: Data, generic: Data, label: String
  ) -> Bool {
    var found: CFTypeRef?
    let query = PasswordSync.readQuery(service: service, account: step.id, store: step.to.store)
    guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
      let target = found as? [String: Any]
    else { return false }
    switch PasswordSync.resolveDuplicate(
      sourceModified: source[kSecAttrModificationDate as String] as? Date,
      targetModified: target[kSecAttrModificationDate as String] as? Date)
    {
    case .keepTarget: return true
    case .updateTarget:
      let values: [String: Any] = [
        kSecValueData as String: secret, kSecAttrGeneric as String: generic,
        kSecAttrLabel as String: label,
      ]
      return SecItemUpdate(
        PasswordSync.itemQuery(service: service, account: step.id, store: step.to.store)
          as CFDictionary, values as CFDictionary) == errSecSuccess
    }
  }

  func setSync(_ on: Bool, offChoice: PasswordSync.OffChoice = .removeFromOtherDevices)
    -> MigrationResult
  {
    let steps = PasswordSync.plan(
      entries: entryPlacements(), enabling: on, offChoice: offChoice)
    let result = migrate(steps)
    // Only flip the setting when every entry moved, so new saves never land in a mixed state.
    if result.failed == 0 {
      syncEnabled = on
      GateSettings.shared.set(on, forKey: Self.syncDefaultsKey)
    }
    reload()
    return result
  }
}

struct PasswordSyncSettings: View {
  @ObservedObject var vault: PasswordVault
  @Binding var status: String
  @Environment(\.palette) var p
  private var availability: PasswordSync.Availability { vault.syncAvailability }
  private var isOn: Bool { vault.syncEnabled && availability.isAvailable }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(
        "Sync passwords with iCloud Keychain",
        isOn: Binding(get: { isOn }, set: { request($0) })
      ).toggleStyle(SettingsToggleStyle()).disabled(!availability.isAvailable)
      Text(note).font(UIStyle.font(12)).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var note: String {
    switch availability {
    case .unavailable(let why): return why
    case .available:
      return isOn
        ? "Saved passwords appear on your other Apple devices signed in to iCloud Keychain. Turn this off to keep them on this Mac only."
        : "Off: passwords stay on this Mac only. Turn on to make them available on your other Apple devices."
    }
  }

  private func request(_ desired: Bool) {
    let placements = vault.entryPlacements()
    let toMove = PasswordSync.plan(entries: placements, enabling: desired).count
    let decision = PasswordSync.decide(
      current: isOn, desired: desired, availability: availability, entriesToMove: toMove)
    switch decision {
    case .noChange: return
    case .unavailable(let why): status = why
    case .apply: finish(desired, .removeFromOtherDevices)
    case .confirmEnable(let count):
      let alert = NSAlert()
      alert.messageText = "Sync \(count) saved password\(count == 1 ? "" : "s") with iCloud Keychain?"
      alert.informativeText =
        "They will be copied to iCloud Keychain and appear on your other Apple devices signed in to it."
      alert.addButton(withTitle: "Turn On Sync")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      finish(true, .removeFromOtherDevices)
    case .confirmDisable(let count):
      let alert = NSAlert()
      alert.messageText = "Stop syncing \(count) saved password\(count == 1 ? "" : "s")?"
      alert.informativeText =
        "Remove from other devices: passwords stay on this Mac only and are deleted from iCloud Keychain on your other devices.\n\nKeep on other devices: existing passwords stay in iCloud Keychain, including on this Mac. Only passwords you save from now on stay on this Mac."
      alert.addButton(withTitle: "Remove from Other Devices")
      alert.addButton(withTitle: "Keep on Other Devices")
      alert.addButton(withTitle: "Cancel")
      switch alert.runModal() {
      case .alertFirstButtonReturn: finish(false, .removeFromOtherDevices)
      case .alertSecondButtonReturn: finish(false, .leaveSynced)
      default: return
      }
    }
  }

  private func finish(_ on: Bool, _ choice: PasswordSync.OffChoice) {
    Task {
      do {
        try await vault.authenticate(
          on ? "Move your Serein passwords to iCloud Keychain" : "Change where Serein passwords are kept")
        let result = vault.setSync(on, offChoice: choice)
        status =
          result.failed == 0
          ? (on ? "Sync is on." : "Sync is off.")
          : "\(result.failed) password\(result.failed == 1 ? "" : "s") could not be moved. Sync setting unchanged; try again."
      } catch { status = error.localizedDescription }
    }
  }
}
