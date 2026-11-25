#if DEBUG
import Foundation
import SereinCore

/// The one-time Allow all upgrade at launch (`AssistantMigration.allowAllLaunch`): an install
/// whose level was never the person's own moves to Allow all once, with a receipt whose Undo goes
/// back on a real Relay and counts as the person's choice, so the upgrade never comes back.
extension AssistantCoreChecks {
  static func allowAllLaunch(_ check: Check) throws {
    let key = AssistantMigration.autopilotKey
    func store() -> UserDefaults {
      let name = "serein-allow-all-\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: name)!
      defaults.removePersistentDomain(forName: name)
      return defaults
    }

    let fresh = store()
    let receipt = AssistantMigration.allowAllLaunch(fresh, gates: fresh)
    try check(ApprovalLevel.resolve(stored: fresh.object(forKey: key)) == .proactive
      && fresh.bool(forKey: ApprovalLevel.allowAllMigratedKey),
      "allow all launch: with no stored level the first launch stores Allow all and marks the upgrade done")
    try check(receipt.flatMap { $0.undo }.flatMap { AssistantMigration.allowAllUndo(entry: $0.entry) } == .everyStep,
      "allow all launch: the first launch gives a receipt whose Undo goes back to Manual, the level before")
    if case .banner(_, _, let action)? = receipt?.card {
      try check(action == "Undo" && ReceiptCopy.lint(receipt!.line).isEmpty,
        "allow all launch: the receipt is a plain line with an Undo button")
    } else {
      try check(false, "allow all launch: the receipt carries a banner with Undo")
    }
    try check(AssistantMigration.allowAllLaunch(fresh, gates: fresh) == nil
      && ApprovalLevel.resolve(stored: fresh.object(forKey: key)) == .proactive,
      "allow all launch: the second launch does nothing and shows nothing")

    let risky = store()
    risky.set(true, forKey: key)
    try check(AssistantMigration.allowAllLaunch(risky, gates: risky)?.undo
      .flatMap { AssistantMigration.allowAllUndo(entry: $0.entry) } == .riskyOnly,
      "allow all launch: an install left on Auto by an old default moves up, and Undo goes back to Auto")

    let chosen = store()
    chosen.set(false, forKey: key)
    chosen.set(true, forKey: ApprovalLevel.userSetKey)
    try check(AssistantMigration.allowAllLaunch(chosen, gates: chosen) == nil
      && chosen.object(forKey: key) as? Bool == false,
      "allow all launch: a level the person chose is never touched")

    let already = store()
    already.set(ApprovalLevel.proactive.rawValue, forKey: key)
    try check(AssistantMigration.allowAllLaunch(already, gates: already) == nil
      && already.bool(forKey: ApprovalLevel.allowAllMigratedKey),
      "allow all launch: an install on Allow all already gets no receipt and the upgrade is marked done")

    try MainActor.assumeIsolated {
      guard RelayOrchestrator.shared == nil else {
        try check(false, "allow all launch: no Relay runs before this suite starts one")
        return
      }
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("serein-allow-all-\(UUID().uuidString)", isDirectory: true)
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: root) }
      let browser = try BrowserModel(root: root)
      try files.createDirectory(
        at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
      let gates = GateSettings.shared
      let gateKeys = [key, ApprovalLevel.defaultedKey, ApprovalLevel.allowAllMigratedKey]
      let kept = gateKeys.map { ($0, gates.object(forKey: $0)) }
      // Outside a real launch the person's choice lives in the argument domain (`setSetting`).
      let defaults = UserDefaults.standard
      let keptArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      defer {
        for (gate, value) in kept { gates.set(value, forKey: gate) }
        defaults.setVolatileDomain(keptArguments, forName: UserDefaults.argumentDomain)
      }
      var arguments = keptArguments
      arguments[ApprovalLevel.userSetKey] = false
      defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
      gates.set(true, forKey: key)
      gates.set(nil, forKey: ApprovalLevel.allowAllMigratedKey)

      let agent = AgentModel(browser: browser, discoverProviders: false)
      let relay = RelayOrchestrator.start(agent: agent, browser: browser)
      defer { RelayOrchestrator.releaseForChecks(relay) }
      let upgrade = AssistantMigration.allowAllLaunch(defaults, gates: gates)
      try check(relay.level == .proactive, "allow all launch: the Relay reads Allow all after the upgrade")
      guard let token = upgrade?.undo else {
        try check(false, "allow all launch: the upgrade from Auto gives a receipt with Undo")
        return
      }
      try check(relay.undoReceipt(token) && relay.level == .riskyOnly && defaults.bool(forKey: ApprovalLevel.userSetKey),
        "allow all launch: Undo puts Auto back and records it as the person's own choice")
      gates.set(nil, forKey: ApprovalLevel.allowAllMigratedKey)
      try check(AssistantMigration.allowAllLaunch(defaults, gates: gates) == nil && relay.level == .riskyOnly,
        "allow all launch: after Undo a later launch never upgrades again")
    }
  }
}
#endif
