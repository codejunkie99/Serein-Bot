#if DEBUG
import Foundation
import SereinCore

/// Allow all as the default (owner 2026-11-25): a fresh install starts there, every other install
/// moves there once with a receipt whose Undo restores its level, and at Allow all only the code
/// floor and the secure card stop a step. A site set to Ask parks its changes on person_step.
extension AssistantCoreChecks {
  static func allowAll(_ check: Check) throws {
    typealias Door = ApprovalDoor
    let key = AssistantMigration.autopilotKey

    // A fresh install is written Allow all, with no one-time Auto consent card.
    let fresh = AssistantMigration.plan(freshInstall: true, enabled: nil, proactive: nil, autopilot: nil, learnsNotes: nil)
    try check(
      ApprovalLevel.newInstallDefault == .proactive && fresh.contains(.string(key, ApprovalLevel.proactive.rawValue))
        && !fresh.contains(.bool(ApprovalLevel.defaultedKey, true)),
      "A fresh install starts at Allow all, with no consent card")
    try check(ApprovalLevel.resolve(stored: nil) == .everyStep, "An unset or unreadable approval setting still reads as Every step")
    let kept = AssistantMigration.plan(freshInstall: true, enabled: nil, proactive: nil, autopilot: false, learnsNotes: nil)
    try check(!kept.contains { if case .string(key, _) = $0 { return true }; return false }, "A fresh install's own stored level is not overwritten by the plan")

    // The move, on a throwaway store per earlier level.
    func store() -> (UserDefaults, String) {
      let name = "serein-allow-all-\(UUID().uuidString)"
      return (UserDefaults(suiteName: name)!, name)
    }
    let earlier: [(Any?, ApprovalLevel)] = [(false, .everyStep), (true, .riskyOnly), (nil, .everyStep), ("junk", .everyStep)]
    for (stored, level) in earlier {
      let (gates, name) = store()
      defer { gates.removePersistentDomain(forName: name) }
      gates.set(stored, forKey: key)
      gates.set(true, forKey: ApprovalLevel.defaultedKey)
      gates.set(true, forKey: ApprovalLevel.userSetKey)
      let moved = AllowAllMigration.run(gates)
      let now = ApprovalLevel.resolve(stored: gates.object(forKey: key))
      try check(
        moved == level && now == .proactive && AllowAllMigration.previous(gates) == level
          && gates.object(forKey: ApprovalLevel.defaultedKey) == nil,
        "An install at \(level.title) (stored \(stored.map { "\($0)" } ?? "nothing")) moves to Allow all once, a level the person chose too, and keeps \(level.title) for Undo")
      // A second launch changes nothing, even after the person went back down.
      gates.set(false, forKey: key)
      try check(
        AllowAllMigration.run(gates) == nil && ApprovalLevel.resolve(stored: gates.object(forKey: key)) == .everyStep,
        "A second launch after the move from \(level.title) does not move it again")
    }
    // Already at Allow all (a fresh install, after AssistantMigration): marked, no receipt.
    do {
      let (gates, name) = store()
      defer { gates.removePersistentDomain(forName: name) }
      gates.set(ApprovalLevel.proactive.storedValue, forKey: key)
      try check(
        AllowAllMigration.run(gates) == nil && AllowAllMigration.previous(gates) == .proactive && AllowAllMigration.run(gates) == nil,
        "An install already at Allow all is marked and shows no receipt")
    }
    // A store that keeps nothing (an unreadable gates file): no move, no receipt, tried again later.
    final class Deaf: SettingsStore {
      func object(forKey key: String) -> Any? { nil }
      func set(_ value: Any?, forKey key: String) {}
      func removeObject(forKey key: String) {}
    }
    try check(AllowAllMigration.run(Deaf()) == nil, "An unreadable store neither moves nor shows a receipt")

    // The receipt: the plain words, a banner whose Undo names the move.
    let receipt = ReceiptCopy.allowAll(entry: AllowAllMigration.undoEntry)
    var undoShown = false
    if case .banner(_, _, "Undo")? = receipt.card { undoShown = true }
    try check(
      receipt.line == "Done. Serein now runs everything without asking. To change it, say “ask me before …”."
        && undoShown && receipt.undo?.entry == AllowAllMigration.undoEntry && receipt.undo?.isLive() == true
        && ReceiptCopy.lint(receipt.line).isEmpty,
      "The move's receipt says so in plain words and offers Undo")

    // Undo on a real Relay: back to the level before, and only while the level is still Allow all.
    try MainActor.assumeIsolated {
      guard RelayOrchestrator.shared == nil else {
        try check(false, "allow all: no Relay runs before this check starts one")
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
      let saved = [key, ApprovalLevel.defaultedKey, ApprovalLevel.userSetKey, AllowAllMigration.markerKey].map { ($0, gates.object(forKey: $0)) }
      defer { for (key, value) in saved { gates.set(value, forKey: key) } }
      let agent = AgentModel(browser: browser, discoverProviders: false)
      let relay = RelayOrchestrator.start(agent: agent, browser: browser)
      defer { RelayOrchestrator.releaseForChecks(relay) }

      gates.set(nil, forKey: AllowAllMigration.markerKey)
      gates.set(ApprovalLevel.riskyOnly.storedValue, forKey: key)
      try check(AllowAllMigration.run(gates) == .riskyOnly && relay.level == .proactive, "allow all: the move lifts a running Relay to Allow all")
      let undone = relay.revert(entry: AllowAllMigration.undoEntry, chat: relay.threadID)
      try check(
        (try? undone.get())?.kind == .undone && relay.level == .riskyOnly && AllowAllMigration.run(gates) == nil,
        "allow all: Undo restores the level before, and the move does not come back")
      relay.setLevel(.proactive)
      relay.setLevel(.everyStep)
      let late = relay.revert(entry: AllowAllMigration.undoEntry, chat: relay.threadID)
      try check(
        (try? late.get()) == nil && relay.level == .everyStep,
        "allow all: an Undo after the level changed again leaves the person's level alone")

      // One yes on a person_step confirm covers that one call (the site's Ask rule then reads normal once).
      let hash = PersonStep.argsHash(["tab": "t1", "ref": "e4"])
      relay.grantConfirm(tool: "click", argsHash: hash, path: nil, task: "allow-all-task")
      try check(
        !relay.takesConfirm(tool: "click", argsHash: PersonStep.argsHash(["tab": "t1", "ref": "e5"]), path: nil, task: "allow-all-task")
          && relay.takesConfirm(tool: "click", argsHash: hash, path: nil, task: "allow-all-task")
          && !relay.takesConfirm(tool: "click", argsHash: hash, path: nil, task: "allow-all-task"),
        "allow all: a confirm yes covers that exact call once")
    }

    // At Allow all, attended or not: mail, web, files, shell and apps run with no card.
    func answer(_ step: Door.Step, _ standing: Door.Standing, site: SiteRule = .normal) -> Door.Answer {
      Door.answer(.init(step, standing, site: site), facts: DoorTable.facts(for: step))
    }
    let standings: [Door.Standing] = [
      .person(.proactive), .proactiveTask(present: false),
      Door.Standing(level: .proactive, levelStands: false, present: false, unattended: true),
    ]
    let steps: [(String, Door.Step)] = [
      ("mail send", .mail(.mailSend)), ("mail delete", .mail(.mailDelete)), ("message", .mail(.messagesSend)),
      ("web click", .action(.init(kind: "click", label: "Submit", effect: .submit))),
      ("web send", .effect(.send)), ("file delete", .effect(.delete)), ("upload", .effect(.upload)),
      ("shell", .command("rm -rf build", mode: .always)), ("shell write", .command("git push", mode: .always)),
      ("app step", .action(.init(kind: "click", label: "Delete note", app: "Notes"))),
      ("calendar", .nativeConnection(tool: "calendar_create")), ("setting", .setting(tool: "app_settings", action: "set")),
      ("downloads", .downloads),
    ]
    let carded = steps.filter { _, step in standings.contains { answer(step, $0).asks || !answer(step, $0).runs } }.map(\.0)
    try check(carded.isEmpty, "At Allow all mail, web, files, shell and apps run with no ask or card"
              + (carded.isEmpty ? "" : ". Asked: \(carded.joined(separator: ", "))"))
    // A site set to Ask parks a change on person_step, never a card, at every level.
    let levels: [Door.Standing] = standings + [.person(.everyStep), .person(.riskyOnly), .noChat(present: true)]
    try check(
      levels.allSatisfy { answer(.effect(.send), $0, site: .ask) == .blocked(.siteAsk) && !answer(.effect(.send), $0, site: .ask).asks },
      "A site set to Ask parks a change on person_step at every level, never as a card")

    // Paying and secrets still go to the secure card; the floor still refuses with a route.
    let none = DoorTable.facts()
    let pressed = Door.Step.effect(.pay)
    let secret = Door.Step.action(.init(kind: "type", label: "Password", role: "AXSecureTextField"))
    let payLine = Boundary.pay(ref: "b7").blocked.text
    try check(
      standings.allSatisfy { Door.answer(.init(pressed, $0), facts: DoorTable.facts(ref: "b7")) == .blocked(.pay(ref: "b7")) }
        && standings.allSatisfy { Door.answer(.init(secret, $0), facts: none) == .blocked(.secret) }
        && payLine.contains("person_step with kind pay") && Boundary.secret.blocked.text.contains("secure_card"),
      "At Allow all paying and secrets still go to the secure card")
    let floor: [(Door.Facts, Boundary)] = [
      (DoorTable.facts(runsAnything: true), .codeRunner), (DoorTable.facts(path: .privateStore), .privateStore),
      (DoorTable.facts(botCheck: true), .botCheck), (DoorTable.facts(hostKeyChanged: "h"), .hostKey(host: "h")),
    ]
    try check(
      floor.allSatisfy { facts, boundary in
        standings.allSatisfy { Door.answer(.init(.effect(.click), $0), facts: facts) == .blocked(boundary) }
          && boundary.blocked.text.contains("Routes: ")
      } && Door.answer(.init(.effect(.click), .person(.proactive), site: .never), facts: none) == .blocked(.siteNever),
      "At Allow all the code floor still refuses, each with a route")
  }
}
#endif
