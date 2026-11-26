import Foundation

/// Fixed files for Serein's private guest. No script, password or path comes from a model.
public enum MacOfflineSetup {
  public static let version = 4
  public static let username = "serein"
  public static let home = "/Users/serein"
  public static let agent = "pro.serein.mac-bootstrap"
  public static let marker = home + "/Library/Application Support/Serein/offline-setup.plist"
  public static let completedMarker = "/private/var/db/.SereinOfflineSetupDone"
  public static let executable = home + "/Applications/Serein Computer.app/Contents/MacOS/serein-mac-guest"

  public static func preferences(build: String, product: String) -> [String: Any] {
    ["DidSeeCloudSetup": true, "DidSeePrivacy": true, "DidSeeSiriSetup": true,
     "DidSeeTouchIDSetup": true, "DidSeeTrueToneSetup": true, "DidSeeAccessibility": true,
     "DidSeeAppearanceSetup": true, "DidSeeScreenTime": true, "DidSeeIntelligence": true,
     "GestureMovieSeen": "none", "LastSeenBuddyBuildVersion": build,
     "LastSeenCloudProductVersion": product]
  }

  public static var loginAgent: [String: Any] {
    ["Label": agent, "ProgramArguments": [executable, "--native-host", "--offline-setup"],
     "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 30,
     "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive", "Umask": 0o077,
     "StandardOutPath": home + "/Library/Application Support/Serein/connection.log",
     "StandardErrorPath": home + "/Library/Application Support/Serein/connection.log"]
  }

  // macOS's autologin format, also documented in Lume's MIT offline setup implementation.
  // Pad before XOR, including a terminator when the password is a multiple of 12 bytes.
  public static func loginPassword(_ password: String) -> Data {
    let key: [UInt8] = [0x7d, 0x89, 0x52, 0x23, 0xd2, 0xbc, 0xdd, 0xea, 0xa3, 0xb9, 0x1f]
    var bytes = Array(password.utf8)
    bytes += Array(repeating: 0, count: 12 - bytes.count % 12)
    return Data(bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] })
  }
  public static func decodeLoginPassword(_ data: Data) -> String? {
    guard !data.isEmpty, data.count <= 1024, data.count % 12 == 0 else { return nil }
    let key: [UInt8] = [0x7d, 0x89, 0x52, 0x23, 0xd2, 0xbc, 0xdd, 0xea, 0xa3, 0xb9, 0x1f]
    let bytes = data.enumerated().map { $0.element ^ key[$0.offset % key.count] }
    guard let end = bytes.firstIndex(of: 0), bytes[end...].allSatisfy({ $0 == 0 }),
      let password = String(bytes: bytes[..<end], encoding: .utf8), !password.isEmpty,
      !password.contains("\n"), !password.contains("\r") else { return nil }
    return password
  }

}
