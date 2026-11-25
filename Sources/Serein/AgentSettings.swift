import SereinCore
import SwiftUI

/// Serein's own settings for agents (AgentSetting), plus updates and agent sign-ins: for Serein's
/// own agents (their settings tools, BrowserModel.perform) and paired outside agents
/// (OutsideAgents). Each caller has asked the door first.
@MainActor enum AgentSettings {
  static func call(_ tool: String, _ a: [String: Any]) throws -> [String: Any] {
    switch tool {
    case "settings_get":
      return ["settings": Dictionary(uniqueKeysWithValues: AgentSetting.allCases.map { ($0.rawValue, $0.show(stored($0))) })]
    case "settings_set": return try set(a["name"] as? String ?? "", a["value"] as? String ?? "")
    case "update": return try update(a["action"] as? String ?? "")
    case "agent_sign_in": return try signIn(a["agent"] as? String ?? "")
    default: throw SereinError.invalid("Unknown settings tool \(tool).")
    }
  }
  private static var defaults: UserDefaults { .standard }
  private static func stored(_ setting: AgentSetting) -> Any {
    switch setting {
    case .appearance: return AppearanceController.shared.preference.rawValue
    case .darkenPages: return defaults.object(forKey: "serein.darkPages") as? Bool ?? true
    case .textSize: return TextSizeController.shared.scale
    case .compact: return defaults.bool(forKey: "serein.compact")
    case .searchEngine: return defaults.string(forKey: "serein.searchEngine") ?? "DuckDuckGo"
    case .tabSleep: return defaults.integer(forKey: "serein.sleepMinutes")
    case .updateChecks: return Updates.shared.checksAutomatically
    case .updateInstalls: return Updates.shared.installsAutomatically
    }
  }
  /// One setting as Settings shows it, in the words `set` takes (`setting_change`).
  static func value(_ setting: AgentSetting) -> String { setting.show(stored(setting)) }
  /// The values Settings shows on one page (`AgentSetting.page`), for `app_read`.
  static func values(on page: String) -> [String: String] {
    Dictionary(uniqueKeysWithValues: AgentSetting.allCases.filter { $0.page == page }.map { ($0.rawValue, $0.show(stored($0))) })
  }
  static func set(_ name: String, _ raw: String) throws -> [String: Any] {
    // Before the name is even looked up, so a setting added to AgentSetting later is refused too.
    guard !SettingsDenylist.refuses(name) else { throw SereinError.invalid(SettingsDenylist.refusal) }
    guard let setting = AgentSetting(rawValue: name) else {
      throw SereinError.invalid(
        "Unknown setting \(name). Settings: " + AgentSetting.allCases.map(\.rawValue).joined(separator: ", ") + ".")
    }
    guard let value = setting.parse(raw) else { throw SereinError.invalid("\(name) takes \(setting.choices).") }
    switch setting {
    case .appearance: AppearanceController.shared.set(AppearancePreference(stored: value as? String))
    case .darkenPages:
      try write(value, "serein.darkPages")
      NotificationCenter.default.post(name: Notification.Name("SereinDarkPagesChanged"), object: nil)
    case .textSize: TextSizeController.shared.set(value as? Double ?? TextSize.standard)
    case .compact: try write(value, "serein.compact")
    case .searchEngine: try write(value, "serein.searchEngine")
    case .tabSleep: try write(value, "serein.sleepMinutes")
    case .updateChecks, .updateInstalls:
      guard Updates.shared.isAvailable else { throw noFeed }
      let on = value as? Bool ?? false
      if setting == .updateChecks {
        Updates.shared.checksAutomatically = on
      } else {
        // Sparkle downloads by itself only while it also checks by itself.
        if on { Updates.shared.checksAutomatically = true }
        Updates.shared.installsAutomatically = on
      }
    }
    return ["setting": name, "value": setting.show(stored(setting))]
  }

  /// Every stored write a tool makes, checked against the denylist by its key as well.
  private static func write(_ value: Any, _ key: String) throws {
    guard !SettingsDenylist.refuses(key) else { throw SereinError.invalid(SettingsDenylist.refusal) }
    defaults.set(value, forKey: key)
  }

  private static let noFeed = SereinError.invalid(
    "Serein Free updates are installed manually.")
  static func update(_ action: String) throws -> [String: Any] {
    let updates = Updates.shared
    guard updates.isAvailable else { throw noFeed }
    switch action {
    case "check":
      updates.check()
      return ["checking": true, "found": updates.pending ?? NSNull()]
    case "install":
      // No prompt, as the user chose; but the restart would stop running tasks, so they finish first (R14).
      let running = updates.activeTasks()
      guard running == 0 else {
        throw Blocked(
          "installing now would restart Serein and stop \(running) running task\(running == 1 ? "" : "s")",
          routes: .init("carry on; the downloaded update installs when Serein quits"))
      }
      if updates.installReady() { return ["installing": updates.pending ?? "the downloaded update", "restarts": true] }
      updates.check()
      return ["installing": false, "checking": true, "note": "No update is downloaded yet. Serein is checking, and its update window offers the version it finds."]
    default: throw SereinError.invalid("update takes check or install.")
    }
  }

  static func signIn(_ name: String) throws -> [String: Any] {
    let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let driver = HarnessDriver.allCases.first(where: {
        let shown = $0.displayName.lowercased()
        return key == $0.rawValue || key == shown || shown.hasPrefix(key + " ")
      })
    else {
      throw SereinError.invalid(
        "Unknown agent \(name). Agents: " + HarnessDriver.allCases.map(\.displayName).joined(separator: ", ") + ".")
    }
    guard HarnessRegistry.shared.snapshots[driver]?.installed == true else {
      throw SereinError.invalid("\(driver.displayName) is not installed on this Mac. Settings › AI apps can install it.")
    }
    guard HarnessActions.shared.run(HarnessCommands.signIn(driver), driver: driver) != nil else {
      throw SereinError.invalid("Serein could not start the sign-in of \(driver.displayName).")
    }
    return ["signing_in": driver.displayName, "note": "A terminal window opened in Serein. The user finishes the sign-in there."]
  }
}
