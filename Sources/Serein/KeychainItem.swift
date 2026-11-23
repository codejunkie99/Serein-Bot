import Foundation
import Security

/// One generic-password Keychain item Serein owns: a plugin's secret or OAuth tokens, the fast
/// steps key. Written device-only and only while unlocked, so it never moves to another Mac with a
/// backup. Saved passwords keep their own vault (PasswordSyncVault); other browsers' items are only
/// read (SignInImport).
struct KeychainItem {
  let service: String
  let account: String
  /// Readable after the first unlock since the Mac started, still on this device only: a link's
  /// secret, so a delivery that comes while the screen is locked can still be checked. Every
  /// other item is readable only while the Mac is unlocked.
  var afterFirstUnlock = false

  private var accessible: CFString {
    afterFirstUnlock ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }
  /// The stored value; nil when there is none or the Keychain refused (locked, or Deny).
  func read() -> String? {
    var request = query
    request[kSecReturnData as String] = true
    var out: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
  /// Whether a value is stored, without reading it: the Keychain shows no dialog for this.
  var exists: Bool { SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess }
  /// Whether a value may be stored: true unless Keychain says there is none (a locked keychain
  /// counts as present). Also asks without reading, so no dialog.
  var mayExist: Bool { SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound }
  /// Replaces the value; nil or empty removes it. False when the old value could not be removed or
  /// the new one could not be added.
  @discardableResult func replace(with value: String?) -> Bool {
    let removed = SecItemDelete(query as CFDictionary)
    guard removed == errSecSuccess || removed == errSecItemNotFound else { return false }
    guard let value, !value.isEmpty else { return true }
    var add = query
    add[kSecValueData as String] = Data(value.utf8)
    add[kSecAttrAccessible as String] = accessible
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }
  /// Moves an item saved before the device-only rule to it. Changes only the attribute, never the
  /// value, so a value saved meanwhile is kept.
  @discardableResult func restrictToThisDevice() -> Bool {
    SecItemUpdate(query as CFDictionary,
                  [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary) == errSecSuccess
  }
  /// The accounts that hold an item under `service`, from their attributes only (no value is
  /// read, so no dialog); nil when there are none or the Keychain refused.
  static func accounts(service: String) -> Set<String>? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return Set((result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String })
  }
}
