import Foundation

/// The settings an agent may read and change when the user asks ("switch to dark mode"): Serein's
/// own agents through their settings tools, paired outside agents through `serein-agent`. Only
/// how Serein looks and runs. Permission switches (access levels, edits, Mac access, sign-in
/// grants, pairings), privacy switches and anything that deletes data are never here.
public enum AgentSetting: String, CaseIterable, Sendable {
  case appearance
  case darkenPages = "darken_pages"
  case textSize = "text_size"
  case compact
  case searchEngine = "search_engine"
  case tabSleep = "tab_sleep"
  case updateChecks = "update_checks"
  case updateInstalls = "update_installs"

  public var choices: String {
    switch self {
    case .appearance: return "system, light or dark"
    case .darkenPages: return "on or off: darken light webpages while Serein is dark"
    case .textSize: return "90% to 160%, in steps of 5%"
    case .compact: return "on or off: hide the sidebar for a slim toolbar"
    case .searchEngine: return "DuckDuckGo, Google or Bing"
    case .tabSleep: return "never, 15, 30 or 60: minutes before a tab you left sleeps"
    case .updateChecks: return "on or off: check the configured feed for updates automatically"
    case .updateInstalls: return "on or off: download and install updates by itself"
    }
  }
  /// The Settings page that shows it (a `SettingsCategory` id).
  public var page: String {
    switch self {
    // Appearance is part of General now; every setting here shows on that page.
    case .appearance, .darkenPages, .textSize, .compact, .searchEngine, .tabSleep, .updateChecks, .updateInstalls:
      return "General"
    }
  }
  /// The stored form of a requested value, or nil when it is not one of the choices.
  public func parse(_ input: String) -> Any? {
    let v = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let flag: Bool? = ["on", "true", "yes"].contains(v) ? true : ["off", "false", "no"].contains(v) ? false : nil
    switch self {
    case .appearance: return AppearancePreference(rawValue: v)?.rawValue
    case .darkenPages, .compact, .updateChecks, .updateInstalls: return flag
    case .textSize:
      guard let n = Double(v.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
      else { return nil }
      let scale = n > 3 ? n / 100 : n
      return TextSize.range.contains(scale) ? TextSize.snap(scale) : nil
    case .searchEngine: return ["duckduckgo": "DuckDuckGo", "google": "Google", "bing": "Bing"][v]
    case .tabSleep:
      let minutes = v.replacingOccurrences(of: "minutes", with: "").trimmingCharacters(in: .whitespaces)
      return minutes == "never" ? 0 : [15, 30, 60].first { String($0) == minutes }
    }
  }
  /// How a stored value reads back: the same words `parse` takes.
  public func show(_ stored: Any) -> String {
    switch self {
    case .textSize: return TextSize.percent(stored as? Double ?? TextSize.standard)
    case .tabSleep: return (stored as? Int).map { $0 == 0 ? "never" : String($0) } ?? "30"
    default:
      if let flag = stored as? Bool { return flag ? "on" : "off" }
      return "\(stored)"
    }
  }
}

/// What no tool may set, whatever `AgentSetting` grows into: the approval level, access levels,
/// Mac access, sign-ins, pairings, privacy switches, passwords and keys. Judged by the words of a
/// setting's name or stored key, split at punctuation and camel case ("serein.fullAccessProjects"
/// is full, access, projects), so a new setting with one of these words is refused before it is
/// written. The person changes these on their Settings page.
public enum SettingsDenylist {
  /// A word that starts with one of these refuses the setting ("approv" covers approval and approvals).
  static let stems: [String] = [
    "autopilot", "approv", "access", "mac", "grant", "permission", "sign", "login", "pair", "privac", "private",
    "track", "cookie", "password", "passkey", "key", "token", "secret", "credential", "consent", "account",
  ]
  public static let refusal =
    "That setting is the person's own: approvals, access, sign-ins, pairings, privacy, passwords and keys change only on their Settings page. Open it for them with app_open."
  public static func refuses(_ nameOrKey: String) -> Bool {
    words(nameOrKey).contains { word in stems.contains { word.hasPrefix($0) } }
  }
  static func words(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    var previousLower = false
    for ch in text {
      guard ch.isLetter || ch.isNumber else {
        if !current.isEmpty { out.append(current) }
        current = ""
        previousLower = false
        continue
      }
      if ch.isUppercase, previousLower, !current.isEmpty {
        out.append(current)
        current = ""
      }
      current += ch.lowercased()
      previousLower = ch.isLowercase || ch.isNumber
    }
    if !current.isEmpty { out.append(current) }
    return out
  }
}
