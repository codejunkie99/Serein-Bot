#if DEBUG
import Foundation
import SereinCore

/// The message bar's permission and effort chips (ComposerChips.swift) on a real Relay over a
/// throwaway library: each permission choice sets its level and reads back its own words, and Allow
/// all survives a reload; the effort chip lists exactly the model's levels, sets the effort the
/// next turn takes, and is gone for a model with none.
extension AssistantCoreChecks {
  static func composerChips(_ check: Check) throws {
    try MainActor.assumeIsolated {
      guard RelayOrchestrator.shared == nil else {
        try check(false, "composer chips: no Relay runs before this suite starts one")
        return
      }
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("serein-chips-\(UUID().uuidString)", isDirectory: true)
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: root) }
      let browser = try BrowserModel(root: root)
      try files.createDirectory(
        at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
      let gates = GateSettings.shared
      let kept = [RelayOrchestrator.autopilotKey, ApprovalLevel.defaultedKey].map { ($0, gates.object(forKey: $0)) }
      defer { for (key, value) in kept { gates.set(value, forKey: key) } }
      let agent = AgentModel(browser: browser, discoverProviders: false)
      let relay = RelayOrchestrator.start(agent: agent, browser: browser)
      defer { RelayOrchestrator.releaseForChecks(relay) }

      try check(
        ApprovalLevel.composerChoices == [.proactive, .riskyOnly, .everyStep]
          && ApprovalLevel.composerChoices.map(\.composerTitle) == ["Allow all", "Auto", "Manual"]
          && ApprovalLevel.composerChoices.allSatisfy { !$0.composerHint.isEmpty },
        "composer chips: the permission chip lists Allow all, Auto and Manual, each with its hint")
      try check(
        RelayController.confirms(.proactive) && RelayController.confirms(.riskyOnly) && !RelayController.confirms(.everyStep),
        "composer chips: Allow all and Auto each wait for their confirmation; Manual is immediate")
      for choice in ApprovalLevel.composerChoices {
        relay.setLevel(choice)
        try check(relay.level == choice && relay.level.composerTitle == choice.composerTitle,
          "composer chips: \(choice.composerTitle) sets \(choice.rawValue) and the chip reads back \(choice.composerTitle)")
      }

      let registry = HarnessRegistry.shared
      let saved = registry.snapshot(.claude)
      defer { registry.assume(.claude, saved) }
      var snapshot = HarnessSnapshot(instance: HarnessInstance(driver: .claude), status: .ready)
      snapshot.installed = true
      snapshot.path = "/usr/bin/true"
      let ladder: [HarnessOption.Choice] = [.init("low", "Low"), .init("medium", "Medium"), .init("max", "Max")]
      snapshot.models = [
        HarnessModel(id: "chips-ladder", name: "Ladder", options: [HarnessOption.select("effort", "Reasoning", ladder)]),
        HarnessModel(id: "chips-flat", name: "Flat"),
      ]
      registry.assume(.claude, snapshot)
      agent.pin(.claude, executable: "/usr/bin/true")
      let id = relay.team.activeID
      _ = relay.setProfileRoute(id, AssistantRoute(provider: Provider.claude.rawValue, model: "chips-ladder"))
      try check(ComposerEffortChip.levels(relay) == ["low", "medium", "max"],
        "composer chips: the effort chip lists exactly the levels the model's app lists")
      let first = relay.assistantEngine(relay.team.active)
      relay.setEffort("max", for: id)
      let next = relay.assistantEngine(relay.team.active)
      try check(first.effort == "medium" && next.effort == "max" && next.model == "chips-ladder" && next.provider == .claude,
        "composer chips: picking Max makes the next turn's effort max on the same model")
      _ = relay.setProfileRoute(id, AssistantRoute(provider: Provider.claude.rawValue, model: "chips-flat"))
      try check(ComposerEffortChip.levels(relay).isEmpty, "composer chips: the effort chip is gone for a model that lists no levels")

      let old = try JSONDecoder().decode(AssistantRoute.self, from: Data(#"{"provider":"claude","model":"m"}"#.utf8))
      let written = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
      try check(old.effort == nil && !written.contains("effort"),
        "composer chips: a route saved before the effort chip reads as the model's own effort and is written as before")

      relay.setLevel(.proactive)
      // A reload reads relay/gates.json: the stored value as JSON gives it back.
      let key = RelayOrchestrator.autopilotKey
      let file = try JSONSerialization.data(withJSONObject: [key: gates.object(forKey: key) as Any])
      let read = try JSONSerialization.jsonObject(with: file) as? [String: Any]
      gates.set(nil, forKey: key)
      gates.set(read?[key], forKey: key)
      RelayOrchestrator.releaseForChecks(relay)
      let reloaded = RelayOrchestrator.start(agent: agent, browser: browser)
      defer { RelayOrchestrator.releaseForChecks(reloaded) }
      try check(
        reloaded !== relay && reloaded.level == .proactive && reloaded.level.composerTitle == "Allow all"
          && reloaded.standing == .proactiveTask(present: true),
        "composer chips: Allow all survives a reload and the chat then stands as a task at Proactive")
    }
  }
}
#endif
