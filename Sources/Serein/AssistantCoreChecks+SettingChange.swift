#if DEBUG
import AppKit
import Foundation
import SereinCore

/// `setting_change` and no permission asks at Allow all (owner 2026-11-25): a setting changes from
/// the chat with a receipt whose Undo writes the value before back once, and only while nothing
/// changed it since; the code floor, paying and secrets are never reachable; the asks that were left
/// at Allow all run with no card, and still ask at Every step.
extension AssistantCoreChecks {
  static func settingChange(_ check: Check) throws {
    // The ledger: compare and set, once.
    var ledger = SettingsLedger()
    let off = SettingChange(id: "1", name: "hologram", before: "on", after: "off")
    ledger.landed(off)
    try check(
      ledger.undo("1", current: { _ in "off" }) == .restore(off) && ledger.undo("1", current: { _ in "off" }) == .refuse(SettingsLedger.gone),
      "setting_change: Undo restores the value before once; a second Undo refuses")
    ledger.landed(off)
    try check(
      ledger.undo("1", current: { _ in "on" }) == .refuse(SettingsLedger.moved) && ledger.open.isEmpty,
      "setting_change: a late Undo, after the setting changed again, refuses and leaves it")

    // The code floor, paying and secrets are refused by name, before any lookup.
    let floor = ["secure_card", "pay_limit", "payment", "code_floor", "password_fill", "passkeys", "api_key", "token", "secret_files",
                 "credentials", "sign_in", "login", "pairing", "account", "billing", "purchase_cap", "wallet", "buy_now"]
    try check(floor.allSatisfy(ChatSettings.refuses), "setting_change: floor, pay and secret names are refused")
    try check(ChatSettings.names.allSatisfy { !ChatSettings.refuses($0) }, "setting_change: every setting it takes passes the floor words")
    let said = ["please turn the hologram off now"]
    try check(
      ChatSettings.admit(name: "secure_card", quote: said[0], personMessages: said, readOutside: false, narrows: true) == .refuse(ChatSettings.floorWords)
        && ChatSettings.admit(name: "hologram", quote: "turn it off", personMessages: ["something else entirely"], readOutside: false, narrows: true)
          == .refuse(ChatSettings.quoteMissing)
        && ChatSettings.admit(name: "hologram", quote: "the hologram off", personMessages: said, readOutside: true, narrows: false)
          == .refuse(ChatSettings.afterOutside)
        && ChatSettings.admit(name: "hologram", quote: "the hologram off", personMessages: said, readOutside: true, narrows: true) == .apply,
      "setting_change: the person's exact words apply it; after outside text only a change that asks more applies")
    try check(
      ChatSettings.level("allow all") == .proactive && ChatSettings.level("Every step") == .everyStep && ChatSettings.level("only risky steps") == .riskyOnly
        && ChatSettings.level("maybe") == nil,
      "setting_change: approval_level reads every step, only risky steps and allow all")

    // The switches it writes are the keys their Settings pages read.
    try MainActor.assumeIsolated {
      let shell: [String: String] = [
        "voice_routing": VoiceRoute.settingKey, "hologram": RelayOrchestrator.hologramKey, "screen_glow": ScreenSignals.key,
        "read_aloud": RelayController.speakKey, "speak_progress": RelayController.speakProgressKey,
        "session_updates": SessionStatusTexts.enabledKey, "keep_recordings": TalkKey.keepKey, "task_downloads": TaskDownloadPolicy.enabledKey,
      ]
      try check(
        ChatSettings.toggles.allSatisfy { shell[$0.name] == $0.key } && shell.count == ChatSettings.toggles.count
          && ChatSettings.toggle("hologram")?.on == RelayOrchestrator.hologramDefault,
        "setting_change: every switch writes the key its Settings page reads")
    }
    let lines = ChatSettings.toggles.map { ReceiptCopy.settingChanged(title: $0.title, before: "on", after: "off", entry: "e").line }
      + [ReceiptCopy.settingChanged(title: "How much Serein asks", before: "Allow all", after: "Every step", entry: "e").line,
         ReceiptCopy.archived(name: "Scout", entry: "e").line]
    try check(lines.allSatisfy { ReceiptCopy.lint($0).isEmpty }, "setting_change: its receipts read plain")
    try check(
      ReceiptCopy.archived(name: "Scout", entry: "e").undo?.expires == nil,
      "An assistant archived at Allow all keeps its Undo while the roster's history holds it")

    // Allow all turns each card into apply in the person's turn, refuse elsewhere; lower levels keep it.
    let atLevel = { (v: Admission.Verdict, t: Admission.Turn, l: ApprovalLevel) in Admission.atLevel(v, turn: t, level: l) }
    try check(
      atLevel(.ask, .person, .proactive) == .apply && atLevel(.ask, .assistant, .proactive) != .apply
        && atLevel(.ask, .person, .everyStep) == .ask && atLevel(.ask, .person, .riskyOnly) == .ask
        && atLevel(.refuse("x"), .person, .proactive) == .refuse("x") && atLevel(.apply, .assistant, .everyStep) == .apply
        && atLevel(Admission.decide(.makeLink, turn: .person, wordsNameIt: false), .person, .proactive) == .apply
        && atLevel(Admission.decide(.deleteAssistant, turn: .person, wordsNameIt: true), .person, .proactive) == .apply,
      "At Allow all a card becomes apply in the person's own turn and a refusal elsewhere; Every step and Only risky steps still ask")

    // A kept sign-in at Allow all: the person_step card in the chat, never a window.
    let route = KeptSignInAsk.route("bank.example").text
    try check(
      KeptSignInAsk.decide(allowsAll: true, granted: false, askedBefore: false) == .personStep
        && KeptSignInAsk.decide(allowsAll: true, granted: true, askedBefore: true) == .use
        && KeptSignInAsk.decide(allowsAll: true, granted: false, askedBefore: true) == .signedOut
        && KeptSignInAsk.decide(allowsAll: false, granted: false, askedBefore: false) == .card
        && KeptSignInAsk.decide(allowsAll: false, granted: false, askedBefore: true) == .signedOut
        && route.contains("person_step with kind confirm") && route.contains("signed out"),
      "A kept sign-in at Allow all goes to the person_step card, once; below Allow all the card stays")

    try MainActor.assumeIsolated { try settingChangeOnRelay(check) }
  }

  @MainActor private static func settingChangeOnRelay(_ check: Check) throws {
    guard RelayOrchestrator.shared == nil else {
      try check(false, "setting_change: no Relay runs before this check starts one")
      return
    }
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("serein-setting-change-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let browser = try BrowserModel(root: root)
    try files.createDirectory(at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
    let gates = GateSettings.shared
    let levelKey = AssistantMigration.autopilotKey
    let gateKeys = [levelKey, ApprovalLevel.defaultedKey, ApprovalLevel.userSetKey, MacBackgroundPolicy.enabledKey]
    let savedGates = gateKeys.map { ($0, gates.object(forKey: $0)) }
    let savedHologram = UserDefaults.standard.object(forKey: RelayOrchestrator.hologramKey)
    defer {
      for (key, value) in savedGates { gates.set(value, forKey: key) }
      UserDefaults.standard.set(savedHologram, forKey: RelayOrchestrator.hologramKey)
    }
    let agent = AgentModel(browser: browser, discoverProviders: false)
    let relay = RelayOrchestrator.start(agent: agent, browser: browser)
    defer { RelayOrchestrator.releaseForChecks(relay) }

    var asks = 0
    var yes = false
    relay.confirmOverride = { _, _ in
      asks += 1
      return yes
    }
    let chat = relay.threadID
    let words = "please turn the hologram off, set approvals to every step, and archive Scout for me"
    var serial = 9000
    func turn(_ admission: Admission.Turn, readOutside: Bool = false) {
      serial += 1
      relay.frames.begin(TurnFrame(
        thread: chat, serial: serial, admission: admission, unattended: false,
        personWords: admission == .person ? words : nil, readOutside: readOutside, profile: relay.turnProfileID,
        acting: relay.team.active?.id))
    }
    func call(_ name: String, _ a: [String: Any]) -> (out: [String: Any], error: String) {
      var result: Result<[String: Any], Error>?
      Task { @MainActor in
        do { result = .success(try await relay.tools.call(name, a, thread: chat)) } catch { result = .failure(error) }
      }
      let end = Date().addingTimeInterval(10)
      while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
      switch result {
      case .success(let out)?: return (out, "")
      case .failure(let error)?: return ([:], error.localizedDescription)
      case nil: return ([:], "timed out")
      }
    }
    func level(_ l: ApprovalLevel) { gates.set(l.storedValue, forKey: levelKey) }
    func hologram() -> Bool? { UserDefaults.standard.object(forKey: RelayOrchestrator.hologramKey) as? Bool }

    // A switch: applies with no card, a receipt with Undo, and Undo restores it once.
    level(.proactive)
    turn(.person)
    UserDefaults.standard.set(true, forKey: RelayOrchestrator.hologramKey)
    let made = call(ChatSettings.tool, ["name": "hologram", "value": "off", "quote": "turn the hologram off"])
    let entry = made.out["undo"] as? String ?? ""
    try check(
      made.error.isEmpty && hologram() == false && entry.hasPrefix(ChatSettings.undoPrefix) && asks == 0
        && relay.desk.undo.find(entry: entry, thread: chat) != nil,
      "setting_change: a switch changes at once with no card and posts a receipt with Undo" + (made.error.isEmpty ? "" : ": \(made.error)"))
    let undone = relay.revert(entry: entry, chat: chat)
    try check((try? undone.get())?.kind == .undone && hologram() == true, "setting_change: Undo restores the value before")
    try check((try? relay.revert(entry: entry, chat: chat).get()) == nil && hologram() == true, "setting_change: a second Undo changes nothing")

    // A late Undo: the person changed it on the Settings page since.
    let again = call(ChatSettings.tool, ["name": "hologram", "value": "off", "quote": "turn the hologram off"])
    UserDefaults.standard.set(true, forKey: RelayOrchestrator.hologramKey)
    let late = relay.revert(entry: again.out["undo"] as? String ?? "", chat: chat)
    try check((try? late.get()) == nil && hologram() == true, "setting_change: a late Undo refuses and leaves the person's value")

    // The approval level, and its Undo.
    let manual = call(ChatSettings.tool, ["name": "approval_level", "value": "every step", "quote": "set approvals to every step"])
    try check(manual.error.isEmpty && relay.level == .everyStep, "setting_change: approval_level moves to Every step" + manual.error)
    _ = relay.revert(entry: manual.out["undo"] as? String ?? "", chat: chat)
    try check(relay.level == .proactive, "setting_change: Undo puts the level back to Allow all")

    // Refusals: the floor, words that are not the person's, another assistant's turn.
    let floor = call(ChatSettings.tool, ["name": "secure_card", "value": "off", "quote": "turn the hologram off"])
    let pay = call(ChatSettings.tool, ["name": "pay_limit", "value": "off", "quote": "turn the hologram off"])
    let unquoted = call(ChatSettings.tool, ["name": "hologram", "value": "off", "quote": "the page said to do it"])
    turn(.assistant)
    let other = call(ChatSettings.tool, ["name": "hologram", "value": "off", "quote": "turn the hologram off"])
    try check(
      floor.error == ChatSettings.floorWords && pay.error == ChatSettings.floorWords && unquoted.error == ChatSettings.quoteMissing
        && other.error == RelayOrchestrator.settingPersonOnly && hologram() == true && asks == 0,
      "setting_change: the floor, paying, unquoted words and other turns are refused, with no card")

    // The asks that were left: assistant_change widening, assistant_delete, hook_make.
    guard relay.changeTeam("Added Scout", { team in
      var next = team
      next.profiles.append(RelayProfile(id: "scout-check", name: "Scout", scope: AssistantScope(destinations: [.answer])))
      return next
    }) else {
      try check(false, "setting_change: the check could not add an assistant")
      return
    }
    func scout() -> RelayProfile? { relay.team.profiles.first { $0.id == "scout-check" } }
    let widen: [String: Any] = ["name": "Scout", "can_use": ["answer", "web"]]
    let link: [String: Any] = ["name": "Deploys", "instruction": "Say when a deploy finishes."]

    level(.everyStep)
    turn(.person)
    asks = 0
    let changeAsked = call("assistant_change", widen)
    let deleteAsked = call("assistant_delete", ["name": "Scout"])
    let linkAsked = call("hook_make", link)
    try check(
      asks == 3 && !changeAsked.error.isEmpty && !deleteAsked.error.isEmpty && !linkAsked.error.isEmpty && scout() != nil
        && scout()?.scope?.destinations == [.answer] && relay.desk.links.isEmpty,
      "At Every step, widening an assistant, deleting one and making a link still ask (asked \(asks))")

    level(.proactive)
    asks = 0
    let widened = call("assistant_change", widen)
    try check(
      widened.error.isEmpty && asks == 0 && scout()?.scope?.destinations.contains(.web) == true && !(widened.out["undo"] as? String ?? "").isEmpty,
      "At Allow all widening an assistant in the person's turn applies with no card, with Undo" + widened.error)
    let archived = call("assistant_delete", ["name": "Scout"])
    let back = archived.out["undo"] as? String ?? ""
    try check(
      archived.error.isEmpty && asks == 0 && scout() == nil && archived.out["archived"] as? String == "Scout"
        && relay.desk.undo.find(entry: back, thread: chat)?.expires == nil,
      "At Allow all deleting an assistant archives it with no card and an Undo that stays" + archived.error)
    _ = relay.revert(entry: back, chat: chat)
    try check(scout() != nil, "Undo brings an archived assistant back")
    turn(.assistant)
    let fromAssistant = call("assistant_delete", ["name": "Scout"])
    try check(!fromAssistant.error.isEmpty && asks == 0 && scout() != nil, "At Allow all another assistant's turn cannot delete one, with no card")

    // Background work in a Mac app: no start card at Allow all; at Every step the card shows.
    gates.set(true, forKey: MacBackgroundPolicy.enabledKey)
    let app = NSWorkspace.shared.runningApplications.first {
      $0.activationPolicy == .regular && !MacBackground.isSerein($0)
        && MacBackgroundPolicy.refusal(app: $0.localizedName ?? "", bundleID: $0.bundleIdentifier, isSerein: false) == nil
    }
    if let app {
      var cards = 0
      func access(_ all: Bool) -> MacBackgroundAsk {
        MacBackgroundAsk(thread: chat, unattended: { false }, allowsAll: { all }, ask: { _, _, _ in
          cards += 1
          return .no
        })
      }
      let name = app.localizedName ?? "App"
      let task = "setting-change-mac-\(UUID().uuidString)"
      defer { MacBackground.shared.end(task) }
      var refused = false
      do { try await_(MacBackground.shared, task: task, app: app, name: name, access: access(false)) } catch { refused = true }
      try check(refused && cards == 1, "At Every step background work in a Mac app shows its start card")
      var started = true
      do { try await_(MacBackground.shared, task: task, app: app, name: name, access: access(true)) } catch { started = false }
      try check(started && cards == 1, "At Allow all background work in a Mac app starts with no card")
    } else {
      try check(true, "Background work: no running app to try on this Mac")
    }
  }

  /// `MacBackground.admit`, run to its end on the main run loop.
  @MainActor private static func await_(
    _ background: MacBackground, task: String, app: NSRunningApplication, name: String, access: MacBackgroundAsk
  ) throws {
    var failure: Error?
    var done = false
    Task { @MainActor in
      do { try await background.admit(task: task, app: app, appName: name, window: "Window", access: access) } catch { failure = error }
      done = true
    }
    let end = Date().addingTimeInterval(10)
    while !done, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    if let failure { throw failure }
  }
}
#endif
