import Foundation

/// App-owned first boot. No setup task, prompt, password or guest image is sent to a model.
public enum MacSetupPhase: Equatable, Sendable {
  case preparing, agreement, account, connecting, ready
  case needsPerson(String)

  public var message: String? {
    switch self {
    case .preparing: return "Preparing Serein’s Mac…"
    case .agreement: return "Review Apple’s macOS agreement to continue automatic setup."
    case .account: return "Creating Serein’s account…"
    case .connecting: return "Connecting Serein to its Mac…"
    case .ready: return nil
    case .needsPerson(let message): return message
    }
  }
  public var needsPerson: Bool {
    switch self {
    case .agreement, .needsPerson: return true
    default: return false
    }
  }
  public var working: Bool { self == .preparing || self == .account || self == .connecting }
}

/// The native USB keyboard uses physical US key positions. Validate the whole string before
/// sending any event; unsupported text must never be partially typed. Unicode uses the signed
/// guest clipboard bridge after it connects, without sharing the host clipboard.
public enum MacGuestKeyboard {
  public static func strokes(_ text: String) -> [MacKey]? {
    guard text.utf8.count <= 32_000 else { return nil }
    let shifted = Dictionary(uniqueKeysWithValues: zip("~!@#$%^&*()_+{}|:\"<>?", "`1234567890-=[]\\;',./"))
    var result: [MacKey] = []
    for char in text {
      let key: MacKey?
      switch char {
      case "\n", "\r\n": key = MacKey.parse("Return")
      case "\t": key = MacKey.parse("Tab")
      case " ": key = MacKey.parse("space")
      default:
        if let base = shifted[char], var found = MacKey.parse(String(base)) {
          found.shift = true; key = found
        } else if char.isASCII, let found = MacKey.parse(String(char).lowercased()) {
          var found = found
          found.shift = char.isUppercase
          key = found
        } else { key = nil }
      }
      guard let key else { return nil }
      result.append(key)
    }
    return result
  }
}

public enum ComputerTargets {
  public static let guidance = """
    There are two separate computer targets. mac_observe/mac_act operate the person's actual Mac and its apps, with the existing per-action approvals. computer_* operates the assistant's separate computer; on a virtual Mac its apps, files, screen coordinates and Command shortcuts belong to that guest. Use the target the person requested, and use the separate computer for the assistant's own work. Never reuse screenshots, coordinates or control refs across targets, or fall back to the person's Mac when the guest is unavailable. Serein's app prepares the guest; do not delegate installation, account creation or permissions to a coding agent. Report its setup state and let the app's setup flow continue. Personal-read exclusions and each target's permissions still apply; access to both targets does not authorize transferring personal data between them.
    """
}
