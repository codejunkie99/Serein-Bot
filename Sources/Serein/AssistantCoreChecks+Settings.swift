#if DEBUG
import Foundation
import SereinCore

/// Settings pages and their sub-pages (`SettingsCategory`): every stored id, label and alias still
/// opens its page, and a sub-page after the page's name opens that page and is read apart.
extension AssistantCoreChecks {
  static func settingsPaths(_ check: Check) throws {
    let ids: [String] = [
      "General", "Appearance", "Relay", "Agents", "Connections", "Privacy", "Passwords", "Plugins",
      "Computer", "Talking", "Keyboard", "Usage",
    ]
    for id in ids {
      try check(SettingsCategory.resolve(id).id == id, "The stored id \(id) opens its page")
    }
    try check(SettingsCategory.resolve("Serein").id == "Relay", "The alias Serein opens the assistants' page")
    try check(SettingsCategory.resolve("Tabs").id == "Appearance", "The old Tabs page opens Appearance, where its layout went")
    try check(SettingsCategory.resolve("AI apps").id == "Agents", "The label AI apps opens Agents")
    try check(SettingsCategory.resolve("Voice").id == "Talking", "The label Voice opens the Talking page")
    try check(SettingsCategory.resolve("Assistants").id == "Relay", "The label Assistants opens the Relay page")
    try check(SettingsCategory.resolve("history").id == "Privacy", "An alias opens its page in any case")
    try check(SettingsCategory.resolve("Nothing like this").id == "General", "An unknown name opens General")
    try check(SettingsCategory.resolve("Relay/abc").id == "Relay", "A sub-page after the page is ignored by resolve")
    try check(SettingsCategory.resolve("Serein/abc/routines").id == "Relay", "An alias with a sub-page opens its page")
    try check(SettingsCategory.subpath("Relay/abc") == ["abc"], "The sub-page after the page is read")
    try check(SettingsCategory.subpath("Relay//abc/routines/") == ["abc", "routines"], "Empty parts are dropped")
    try check(SettingsCategory.subpath("Relay").isEmpty, "A plain page has no sub-page")
    try check(SettingsCategory.request("Relay", path: ["abc"]) == "Relay/abc", "A request joins the page and its sub-page")
    try check(SettingsCategory.request("Relay", path: []) == "Relay", "A request with no sub-page is the page's id")
    let all = SettingsCategory.all
    let names: [String] = all.map(\.id) + all.map(\.label) + all.flatMap(\.aliases)
    try check(!names.contains { $0.contains(SettingsCategory.separator) }, "No id, label or alias holds the separator")
    try check(all.allSatisfy { !$0.summary.isEmpty }, "Every page has its one sentence")
  }

  /// The sign-in step for every AI app: the CLI's own signed-out errors, and the button's words.
  static func signIn(_ check: Check) throws {
    let signedOut = [
      "Not logged in · Please run /login", "Invalid API key · Please run /login",
      "OAuth token has expired. Please obtain a new token or refresh your existing token.",
      "Error: Not logged in. Run `codex login`.", "unexpected status 401 Unauthorized",
      "Authentication required", "Please set an Auth method in your settings.json",
      "Not authenticated. Run cursor-agent login.",
    ]
    for error in signedOut {
      try check(HarnessParse.asksSignIn(error), "A signed-out error asks for sign-in: \(error)")
    }
    let other = [
      "Claude AI usage limit reached|1800000000", "Codex exited (1). network timeout",
      "Stopped after 20 minutes, the limit for this kind of task.",
      String(repeating: "log line ", count: 80) + "not logged in",
    ]
    for error in other {
      try check(!HarnessParse.asksSignIn(error), "Another error does not ask for sign-in: \(error.prefix(40))")
    }
    for driver in HarnessDriver.allCases {
      let name = driver.displayName
      try check(HarnessParse.signInTitle(name, action: .signIn) == "Sign in to \(name)", "\(name) signs in from its button")
      try check(HarnessParse.signInTitle(name, action: .install) == "Install \(name)", "\(name) installs from its button")
      try check(HarnessParse.signInTitle(name, action: .update) == "Update \(name)", "\(name) updates from its button")
      try check(HarnessParse.signInTitle(name, action: .checking) == "Connect \(name)", "\(name) connects while unknown")
    }
    var snapshot = HarnessSnapshot(instance: HarnessInstance(driver: .claude), status: .ready)
    snapshot.checkedAt = Date()
    snapshot.installed = true
    snapshot.signedIn = false
    try check(HarnessPrimaryAction.of(snapshot) == .signIn, "An installed app that is signed out needs Sign in")
  }
}
#endif
