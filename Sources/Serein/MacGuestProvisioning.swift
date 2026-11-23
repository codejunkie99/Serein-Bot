import Foundation
import Security
import SereinCore
import Virtualization

// macOS 27 public APIs, late-bound so the app still builds with the macOS 26 SDK.
// https://developer.apple.com/documentation/virtualization/vzmacguestprovisioningoptions
@objc private protocol MacGuestProvisioningAPI {
  @objc(setGuestProvisioningOptions:error:)
  func setGuestProvisioningOptions(_ options: NSObject, error: NSErrorPointer) -> Bool
}

enum MacGuestProvisioning {
  static var available: Bool {
    if #available(macOS 27, *) {
      return NSClassFromString("VZMacGuestProvisioningOptions") != nil
        && VZMacOSVirtualMachineStartOptions.instancesRespond(to: NSSelectorFromString("setGuestProvisioningOptions:error:"))
    }
    return false
  }

  /// The password stays in this Mac's Keychain and Apple's provisioning call for this guest.
  static func startOptions(storage: URL) throws -> VZMacOSVirtualMachineStartOptions? {
    guard available, let type = NSClassFromString("VZMacGuestProvisioningOptions") as? NSObject.Type else { return nil }
    let provisioning = type.init()
    let values: [String: Any] = [
      "fullName": "Serein", "username": "serein", "password": try password(storage: storage),
      "logsInAutomatically": true, "enablesRemoteLogin": false,
    ]
    for (key, value) in values {
      let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
      guard provisioning.responds(to: NSSelectorFromString(setter)) else {
        throw SereinError.invalid("Automatic Mac setup is unavailable in this version of macOS.")
      }
      provisioning.setValue(value, forKey: key)
    }
    let options = VZMacOSVirtualMachineStartOptions()
    try apply(provisioning, to: options)
    return options
  }

  /// Apple's setter validates the account before the guest starts. Refused options never
  /// silently fall back to a first boot without the requested account.
  static func apply(_ provisioning: NSObject, to options: NSObject) throws {
    guard options.responds(to: NSSelectorFromString("setGuestProvisioningOptions:error:")),
      let set = (options as AnyObject).setGuestProvisioningOptions
    else { throw SereinError.invalid("Automatic Mac setup is unavailable in this version of macOS.") }
    var error: NSError?
    guard set(provisioning, &error) else {
      // Do not echo an API error that could contain account values.
      throw SereinError.invalid("macOS could not validate the automatic Mac setup. The computer was not started.")
    }
  }

  static func password(storage: URL, migrateLegacy: Bool = false) throws -> String {
    let identity = try Data(contentsOf: storage.appendingPathComponent("identity.bin"))
    guard !identity.isEmpty, identity.count <= 4096 else { throw SereinError.invalid("The Mac's private identity is unavailable.") }
    let account = ComputerPins.sha256(identity)
    let item = KeychainItem(service: "pro.serein.mac-guest", account: account)
    if let stored = item.read(), !stored.isEmpty { return stored }
    guard !item.mayExist else { throw SereinError.invalid("Unlock this Mac's Keychain to continue setting up Serein's Mac.") }
    if migrateLegacy {
      let old = KeychainItem(service: "pro.serein.mac-guest", account: ComputerPins.sha256(Data(storage.standardizedFileURL.path.utf8)))
      if let value = old.read(), !value.isEmpty {
        guard item.replace(with: value) else { throw SereinError.invalid("The private Mac credentials could not be migrated.") }
        return value
      }
      throw SereinError.invalid("This existing Mac's private credentials are unavailable. Its account was left untouched.")
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw SereinError.invalid("A secure password for Serein's Mac could not be created.")
    }
    let value = "Serein-1!" + Data(bytes).base64EncodedString()
    guard item.replace(with: value) else { throw SereinError.invalid("Serein's Mac password could not be saved in this Mac's Keychain.") }
    return value
  }
}
