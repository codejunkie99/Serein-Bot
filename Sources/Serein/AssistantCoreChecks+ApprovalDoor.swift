#if DEBUG
import Foundation
import SereinCore

/// The one door (`ApprovalDoor.answer`) against its own table: each Boundary arm, each level with
/// the person there or not and the turn attended or not, a site set to Ask, and the effect a
/// command, or text typed into a terminal, gets from the door's classifier.
/// How to rerun and read a failure: .claude/skills/proactive-safety/SKILL.md.
extension AssistantCoreChecks {
  static func approvalDoor(_ check: Check) throws {
    typealias Door = ApprovalDoor
    typealias Gate = ApprovalGate
    let none = DoorTable.facts()
    func answer(_ step: Door.Step, _ standing: Door.Standing, site: SiteRule = .normal, _ facts: Door.Facts? = nil)
      -> Door.Answer
    {
      Door.answer(.init(step, standing, site: site), facts: facts ?? DoorTable.facts(for: step))
    }
    let hold = Door.Answer.card(.hold(cap: Door.holdCap))

    // The owner's first case: Allow all runs a send with nobody there, as it runs an attended one.
    let away = Door.Standing(level: .proactive, levelStands: true, present: false, unattended: true)
    try check(answer(.effect(.send), away) == .run, "At Allow all a send runs with nobody there and the turn unattended")

    // Every level, the person there or not, the turn attended or not: outside the floor, Every
    // step shows a card for each step that changes something, and every other level runs it.
    let walk = DoorTable.differences()
    try check(
      walk.found.isEmpty,
      walk.found.isEmpty
        ? "The door answers by its table at every level and turn, for \(walk.walked) questions"
        : "The door left its table. \(walk.found.first ?? "")")
    // The walk itself: a door that runs every step at Every step, and one that runs a payment at
    // one level only, are reported.
    let lax = DoorTable.differences { request, facts in
      request.standing.level == .everyStep ? .run : Door.answer(request, facts: facts)
    }
    let leaky = DoorTable.differences { request, facts in
      request.standing.level == .riskyOnly && Door.effect(of: request.step) == .pay ? .run : Door.answer(request, facts: facts)
    }
    try check(!lax.found.isEmpty && !leaky.found.isEmpty,
              "The table reports a door that skips Every step's card, and one that pays at one level")

    // Each Boundary arm, from the fact or the step's own structure, the same at every level and turn.
    let pressed = Gate.GateAction(kind: "click", label: "Next")
    func fact(
      secureField: Bool = false, botCheck: Bool = false, pays: Door.PaySense = .no, covered: Bool = false,
      path: Door.PathPlace? = nil, hostKeyChanged: String? = nil, runsAnything: Bool = false
    ) -> Door.Facts {
      DoorTable.facts(
        secureField: secureField, botCheck: botCheck, pays: pays, covered: covered, path: path,
        hostKeyChanged: hostKeyChanged, runsAnything: runsAnything, ref: "b7")
    }
    let arms: [(name: String, step: Door.Step, site: SiteRule, facts: Door.Facts, boundary: Boundary)] = [
      ("siteNever", .effect(.read), .never, none, .siteNever),
      ("privateStore by path", .effect(.read), .normal, fact(path: .privateStore), .privateStore),
      ("privateStore by app", .action(.init(kind: "click", label: "Copy", app: "1Password")), .normal, none, .privateStore),
      ("codeRunner", .action(pressed), .normal, fact(runsAnything: true), .codeRunner),
      ("secret by fact", .action(pressed), .normal, fact(secureField: true), .secret),
      ("secret by role", .action(.init(kind: "type", label: "Code", role: "AXSecureTextField")), .normal, none, .secret),
      ("secret by label", .action(.init(kind: "type", label: "Enter your password", role: "AXTextField")), .normal, none, .secret),
      ("secret by script", .script("do shell script \"ls\" with administrator privileges"), .normal, none, .secret),
      ("botCheck", .effect(.click), .normal, fact(botCheck: true), .botCheck),
      ("hostKey", .effect(.change), .normal, fact(hostKeyChanged: "build.example"), .hostKey(host: "build.example")),
      ("pay by amount", .action(pressed), .normal, fact(pays: .yes(amount: "$49.00")), .pay(ref: "b7")),
      ("pay unreadable", .action(pressed), .normal, fact(pays: .unreadable), .pay(ref: "b7")),
      ("pay by effect", .effect(.pay), .normal, fact(), .pay(ref: "b7")),
    ]
    let broken = arms.filter { arm in
      !DoorTable.standings.allSatisfy { answer(arm.step, $0, site: arm.site, arm.facts) == .blocked(arm.boundary) }
    }.map(\.name)
    try check(broken.isEmpty, "Each floor blocks at every level and turn (\(arms.count) arms)"
              + (broken.isEmpty ? "" : ". Broken: \(broken.joined(separator: "; "))"))
    try check(
      (arms.map(\.boundary) + [.siteAsk]).allSatisfy { $0.blocked.text.hasPrefix("Blocked: ") },
      "Every arm, a site set to Ask too, answers with a Blocked line")
    // The order: with every fact on, the first arm wins, and each arm wins once those above it are off.
    let order: [(SiteRule, Door.Facts, Boundary)] = [
      (.never, fact(secureField: true, botCheck: true, pays: .unreadable, path: .privateStore, hostKeyChanged: "h", runsAnything: true), .siteNever),
      (.normal, fact(secureField: true, botCheck: true, pays: .unreadable, path: .privateStore, hostKeyChanged: "h", runsAnything: true), .privateStore),
      (.normal, fact(secureField: true, botCheck: true, pays: .unreadable, hostKeyChanged: "h", runsAnything: true), .codeRunner),
      (.normal, fact(secureField: true, botCheck: true, pays: .unreadable, hostKeyChanged: "h"), .secret),
      (.normal, fact(botCheck: true, pays: .unreadable, hostKeyChanged: "h"), .botCheck),
      (.normal, fact(pays: .unreadable, hostKeyChanged: "h"), .hostKey(host: "h")),
      (.normal, fact(pays: .unreadable), .pay(ref: "b7")),
    ]
    try check(
      order.allSatisfy { site, facts, boundary in
        answer(.action(pressed), .person(.riskyOnly), site: site, facts) == .blocked(boundary)
      },
      "The floor's arms win in their fixed order")

    // Paying the person already covered runs.
    let covered = fact(pays: .yes(amount: "$5"), covered: true)
    try check(
      answer(.action(pressed), .person(.riskyOnly), covered) == .run
        && answer(.effect(.pay), .proactiveTask(present: false), covered) == .run,
      "A payment the secure card or a grant covers runs")

    // A site set to Ask every step: a read runs, every other step is parked on the person's
    // confirm card at every level, never a held card.
    try check(
      DoorTable.standings.allSatisfy { standing in
        answer(.effect(.read), standing, site: .ask, none) == .run
          && answer(.effect(.send), standing, site: .ask, none) == .blocked(.siteAsk)
      } && Boundary.siteAsk.blocked.text.contains("person_step with kind confirm"),
      "A site set to Ask parks each changing step on person_step confirm at every level, and reads run")
    try check(
      answer(.effect(.send), .noChat(present: true)) == .card(.deferred) && answer(.effect(.send), .person(.everyStep)) == hold,
      "A card holds the call only when the person's own level stands; with no chat it stays open")

    // The answer's helpers, as callers read them.
    func thrown(_ answer: Door.Answer) -> String? {
      do {
        _ = try answer.decision()
        return nil
      } catch {
        return (error as? LocalizedError)?.errorDescription
      }
    }
    let pay = Door.Answer.blocked(.pay(ref: ""))
    let payLine = Boundary.pay(ref: "").blocked.text
    try check(
      (try? Door.Answer.run.decision()) == .auto && (try? hold.decision()) == .ask
        && thrown(.blocked(.siteAsk)) == Boundary.siteAsk.blocked.text
        && thrown(pay) == payLine && thrown(.checkFirst("Check first.")) == "Check first."
        && pay.said == payLine && Door.Answer.run.said == nil && hold.said == nil
        && Door.Answer.run.runs && hold.asks && !pay.runs && !pay.asks,
      "A run is auto, a card asks, and a Blocked or check line is thrown as a normal result")

    // Commands: never a read, and their words give the effect.
    try check(
      LocalExecution.Mode.allCases.allSatisfy { !Door.reads(.command("ls -la", mode: $0)) }
        && answer(.command("ls -la", mode: .always), .person(.everyStep)) == hold
        && answer(.command("ls -la", mode: .always), .person(.riskyOnly)) == .run
        && answer(.command("stripe charges create --amount 500", mode: .always), .proactiveTask(present: true)) == pay,
      "A command is never a read, and a paying command meets the pay floor")
    let risky = Set(LocalExecution.riskyWords)
    let named = LocalExecution.payWords + LocalExecution.secretWords + LocalExecution.deleteWords
    try check(
      named.allSatisfy(risky.contains) && LocalExecution.terminals.isSubset(of: RelayAutonomy.guardedApps)
        && LocalExecution.terminals.allSatisfy { Door.runsAnything(app: $0) } && !Door.runsAnything(app: "System Settings"),
      "Every word that gives a command an effect is a risky word, and every terminal runs anything")
    let unseen = DoorTable.commandsNotSeen()
    try check(
      unseen == DoorTable.knownCommandsNotSeen,
      "A labelled paying or password command is rated as one, except the listed ones"
        + DoorTable.drift(now: unseen, listed: DoorTable.knownCommandsNotSeen))
    func typed(_ app: String, _ text: String) -> Gate.Effect {
      Door.effect(of: .macStep(RelayAutonomy.MacStep(app: app, kind: "type", role: "AXTextArea", text: text)))
    }
    try check(
      typed("Terminal", "stripe charges create --amount 500") == .pay && typed("iTerm2", "sudo ls") == .access
        && typed("Notes", "stripe charges create --amount 500") != .pay,
      "Text typed into a terminal is read as a command, and text typed elsewhere is not")

    try check(
      ApprovalLevel.chatChoices == [.everyStep, .riskyOnly, .proactive]
        && ApprovalLevel.resolve(stored: nil) == .everyStep
        && ApprovalLevel.resolve(stored: false) == .everyStep
        && ApprovalLevel.resolve(stored: true) == .riskyOnly
        && ApprovalLevel.resolve(stored: "proactive") == .proactive,
      "Chat offers all three levels and restores each saved choice, defaulting a lost choice to Every step")
  }
}

/// The door's table, walked: every step kind Serein asks about, at every standing.
enum DoorTable {
  typealias Door = ApprovalDoor
  typealias Gate = ApprovalGate
  static let bools = [false, true]

  /// Every level, the level standing or not, the person there or not, the turn attended or not.
  static let standings: [Door.Standing] = ApprovalLevel.allCases.flatMap { level in
    bools.flatMap { stands in
      bools.flatMap { present in
        bools.map { unattended in Door.Standing(level: level, levelStands: stands, present: present, unattended: unattended) }
      }
    }
  }

  /// Facts for checks: nothing seen unless named.
  static func facts(
    secureField: Bool = false, botCheck: Bool = false, pays: Door.PaySense = .no, covered: Bool = false,
    path: Door.PathPlace? = nil, hostKeyChanged: String? = nil, runsAnything: Bool = false, ref: String = ""
  ) -> Door.Facts {
    Door.Facts(
      secureField: secureField, botCheck: botCheck, pays: pays, covered: covered, path: path,
      hostKeyChanged: hostKeyChanged, runsAnything: runsAnything, ref: ref)
  }

  /// What a caller sees from the step alone: whether the app it drives runs anything.
  static func facts(for step: Door.Step) -> Door.Facts {
    switch step {
    case .action(let action): return facts(runsAnything: Door.runsAnything(app: action.app ?? ""))
    case .macStep(let step): return facts(runsAnything: Door.runsAnything(app: step.app))
    default: return facts()
    }
  }

  /// Every step the table walks.
  static func steps() -> [(name: String, step: Door.Step)] {
    var steps: [(name: String, step: Door.Step)] = Gate.Effect.allCases.map { ("effect \($0.rawValue)", .effect($0)) }
    var actions = AutonomyDial.actions.map(\.probe)
    actions += ["Next", "Merge", "Send", "Pay now", ""].map { Gate.GateAction(kind: "click", label: $0) }
    let apps = RelayAutonomy.refusedApps.sorted() + RelayAutonomy.guardedApps.sorted() + ["1Password 7", "Safari", ""]
    let roles: [String?] = [nil, "AXButton", "AXTextField", "AXSecureTextField"]
    actions += apps.flatMap { app in roles.map { Gate.GateAction(kind: "click", label: "Next", app: app, role: $0) } }
    for (index, action) in actions.enumerated() {
      steps.append(("action \(index) \(action.app ?? "-") \(action.label ?? "-")", .action(action)))
    }
    for item in ApprovalCases.all {
      switch item.step {
      case .mac(let step): steps.append((item.id, .macStep(step)))
      case .script(let source): steps.append((item.id, .script(source)))
      case .command(let command):
        for mode in LocalExecution.Mode.allCases { steps.append(("\(item.id) \(mode.rawValue)", .command(command, mode: mode))) }
      case .plugin(let name, let declared): steps.append((item.id, .plugin(name: name, declared: declared)))
      case .page, .connector: break
      }
    }
    let settings = [
      ("settings_get", ""), ("settings_set", ""), ("update", "check"), ("update", "install"), ("agent_sign_in", ""),
      ("shortcut_save", ""), ("anything_else", ""),
    ]
    for (tool, action) in settings { steps.append(("setting \(tool) \(action)", .setting(tool: tool, action: action))) }
    let native = [
      "calendar_list", "reminder_list_apple", "contacts_find", "notes_search", "notes_read", "calendar_create",
      "calendar_update", "reminder_create_apple", "notes_create", "notes_append", "calendar_delete", "anything_else",
    ]
    for tool in native {
      for yesWaits in bools { steps.append(("native \(tool) \(yesWaits)", .nativeConnection(tool: tool, yesWaits: yesWaits))) }
    }
    let names = ["list_items", "lookup_order", "send_invoice", "pay_invoice", "create_invoice_payment", "delete_file", "charge_card"]
    let declared: [PluginManifest.Risk?] = [nil] + PluginManifest.Risk.allCases.map { Optional($0) }
    let structural: [Gate.Effect?] = [nil, .read]
    for name in names {
      for risk in declared {
        for effect in structural {
          steps.append(
            ("plugin \(name) \(risk?.rawValue ?? "none") \(effect?.rawValue ?? "-")", .plugin(name: name, declared: risk, effect: effect)))
        }
      }
    }
    for tool in Connections.Tool.allCases {
      for allowed in bools { steps.append(("mail \(tool.rawValue) \(allowed)", .mail(tool, scheduledAllowed: allowed))) }
    }
    let acts: [(String, String?, String?)] = [
      ("computer_click", nil, nil), ("computer_type", nil, "hello"), ("computer_key", "return", nil),
      ("computer_key", "cmd+q", nil), ("computer_scroll", nil, nil), ("computer_open_url", nil, nil),
      ("computer_run", nil, "ls"), ("computer_run", nil, "sudo ls"), ("anything_else", nil, nil),
    ]
    for (tool, key, text) in acts {
      steps.append(("own \(tool) \(key ?? "-") \(text ?? "-")", .ownMachine(tool: tool, key: key, text: text)))
    }
    steps.append(("downloads", .downloads))
    return steps
  }

  /// The table's answer. A step the floor blocks is blocked alike at every level and turn (the
  /// answer at Allow all, attended, is the reference). Otherwise Every step shows a card for a
  /// step that changes something, holding the call only when the person is there and their level
  /// stands, and every other answer runs.
  static func differences(
    through door: (Door.Request, Door.Facts) -> Door.Answer = { Door.answer($0, facts: $1) }
  ) -> (walked: Int, found: [String]) {
    var walked = 0
    var found: [String] = []
    for (name, step) in steps() {
      let facts = facts(for: step)
      let floor = Door.answer(.init(step, .proactiveTask(present: true)), facts: facts)
      for standing in standings {
        let want: Door.Answer
        if case .blocked = floor {
          want = floor
        } else if standing.level == .everyStep, !Door.reads(step) {
          want = .card(standing.present && standing.levelStands ? .hold(cap: Door.holdCap) : .deferred)
        } else {
          want = .run
        }
        let now = door(.init(step, standing), facts)
        walked += 1
        if now != want {
          found.append(
            "\(name) at \(standing.level.rawValue) stands=\(standing.levelStands) present=\(standing.present) "
              + "unattended=\(standing.unattended): \(now), the table \(want)")
        }
      }
    }
    return (walked, found)
  }

  /// Labelled paying and password commands the classifier gives another effect.
  static let knownCommandsNotSeen: Set<String> = []

  static func commandsNotSeen() -> Set<String> {
    Set(ApprovalCases.all.compactMap { item -> String? in
      guard case .command(let command) = item.step, item.label != .neither else { return nil }
      let wanted: Gate.Effect = item.label == .pay ? .pay : .access
      return LocalExecution.effect(of: command) == wanted ? nil : item.id
    })
  }

  static func drift(now: Set<String>, listed: Set<String>) -> String {
    guard now != listed else { return "" }
    return ". Not listed: \(now.subtracting(listed).sorted()). Listed but no longer so: \(listed.subtracting(now).sorted())"
  }
}
#endif
