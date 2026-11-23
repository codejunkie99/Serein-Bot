import Foundation

/// The native macOS desktop. Serein owns setup and native screen/input; a signed guest bridge
/// supplies Unicode text and URLs without guest screen-control grants. No host home, clipboard,
/// microphone or camera is shared.
public enum MacComputerPolicy {
  public static let storageKey = "serein.computer.mac.storage"
  /// Per assistant: the person's own network choice. Absent means `networkByDefault`.
  public static let internetKey = "serein.computer.mac.internet"
  /// Serein's Mac has Apple's normal networking once its setup is finished, so it is online
  /// without anyone doing anything. Setup's own boots stay offline. The person can turn it off.
  public static let networkByDefault = true
  public static func networkOn(stored: Bool?) -> Bool { stored ?? networkByDefault }
  /// Per assistant: a chat that read the person's private things has used this Mac, so its disk
  /// may hold them. Turning its network on says so first.
  public static let heldPrivateKey = "serein.computer.mac.held-private"
  /// Serein's own Mac is part of Serein (the person's choice): every chat may use it, including
  /// one that read their private things, with its network on or off. Its disk is marked when such
  /// a chat used it, and turning the network on says so.
  public static func takesPrivateChats(internet: Bool) -> Bool { true }
  public static let heldPrivateWarning = " Chats that read your private files, mail or Mac apps have used this Mac, so what they left on it could leave too."
  public static let diskBytes: UInt64 = 64 * 1_073_741_824
  public static let minimumFreeBytes: Int64 = 60 * 1_073_741_824
  public static let guestBundleID = "pro.serein.computer-guest"
  public static let guestAppName = "Serein Computer.app"
  public static let guestExecutable = "serein-mac-guest"
  public static let setupLine = "Serein is preparing its Mac. Its app handles setup; wait for it to be ready instead of using another agent to configure it."
  public static let helperSetupLine = "Serein is connecting its Mac’s text connection. Its app handles this setup automatically."
  public static let screenTools: Set<String> = [
    "computer_screenshot", "computer_click", "computer_type", "computer_key", "computer_scroll", "computer_open_url", "computer_send_text",
  ]
  /// Shell and files, answered by the guest app (MacGuestShell).
  public static let shellTools: Set<String> = ["computer_run", "computer_read_file", "computer_send_file"]
  /// Every computer tool the virtual Mac answers.
  public static let tools: Set<String> = screenTools.union(shellTools)
  public static let unsupportedTool = "This virtual Mac supports screenshots, clicks, typing, keys, scrolling, opening websites, shell commands and reading or sending files. Accessibility trees are not available in this Mac yet."

  public static func directory(root: URL, assistantID: String) -> URL? {
    guard !assistantID.isEmpty, assistantID.count <= 64,
      assistantID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else { return nil }
    return root.appendingPathComponent("machines", isDirectory: true).appendingPathComponent(assistantID, isDirectory: true)
  }

  public static func appleDownload(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil,
      let host = url.host?.lowercased(), url.port == nil || url.port == 443
    else { return false }
    return host == "apple.com" || host.hasSuffix(".apple.com") || host == "cdn-apple.com" || host.hasSuffix(".cdn-apple.com")
  }
}

public struct MacGuestFailure: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct MacGuestRequest: Codable {
  public let id: UUID
  public let action: String
  public let arguments: [String: String]
  public let deadline: Date
  public init(action: String, arguments: [String: String] = [:], timeout: TimeInterval = 15) {
    id = UUID(); self.action = action; self.arguments = arguments; deadline = Date().addingTimeInterval(timeout)
  }
}

public struct MacGuestReply: Codable {
  public let id: UUID
  public let ok: Bool
  public let values: [String: String]
  public let error: String?
  public init(id: UUID, values: [String: String] = [:], error: String? = nil) {
    self.id = id; ok = error == nil; self.values = values; self.error = error
  }
}
