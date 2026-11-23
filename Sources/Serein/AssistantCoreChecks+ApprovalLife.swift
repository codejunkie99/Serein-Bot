#if DEBUG
import Foundation
import SereinCore

/// How an approval ends without an answer (ApprovalLife.swift), the one list of standing yeses
/// (StandingYes.swift), the one “Ask before” wording, and how a Mac step follows the level.
extension AssistantCoreChecks {
  static func approvalLife(_ check: Check) throws {
    try approvalEnds(check)
    try standingYeses(check)
    try askBeforeWords(check)
    try macStepLevel(check)
  }

  private static func approvalEnds(_ check: Check) throws {
    typealias L = ApprovalLife
    try check(L.skips(cardThread: "chat", background: false, messageThread: "chat"), "A new message closes the card its own chat waits on")
    try check(!L.skips(cardThread: "task", background: false, messageThread: "chat"), "A message in one chat leaves another chat's card open")
    try check(!L.skips(cardThread: "chat", background: true, messageThread: "chat"), "A new message leaves a background card for its own clock")

    let asked = Date(timeIntervalSince1970: 1_000_000)
    let waited = { (seconds: TimeInterval) in RelayApproval.duty(askedAt: asked, remindedAt: nil, now: asked.addingTimeInterval(seconds)) }
    try check(waited(1_800) == RelayApproval.Duty.none && waited(31 * 60) == RelayApproval.Duty.none,
      "A background approval no longer closes at 30 minutes")
    try check(waited(RelayApproval.remindAfter) == .remind && waited(RelayApproval.declineAfter) == .decline
      && RelayApproval.declineAfter == RelayDeferred.lifetime,
      "Every approval is reminded at four hours and closes at a day, the life of a deferred card's one-time yes")
    try check(L.line(.skipped).word == "Skipped" && L.line(.expired).word == "Expired", "A card that ended by itself says skipped or expired, never declined")

    var denials = L.Denials()
    let send: String = L.Denials.key(title: "Click Send in Mail", detail: "This sends it.", thread: "chat")
    try check(!denials.blocks(send), "Nothing is refused before a denial")
    denials.deny(send)
    try check(denials.blocks(send), "A declined action is not asked again")
    try check(!denials.blocks(L.Denials.key(title: "Click Send in Mail", detail: "This sends it.", thread: "task")), "A denial holds in its own chat only")
    try check(!denials.blocks(L.Denials.key(title: "Click Save in Mail", detail: "This sends it.", thread: "chat")), "A denial holds for that exact action only")
    let other: String = L.Denials.key(title: "Click Send in Mail", detail: "This sends it.", thread: "task")
    denials.deny(other)
    denials.personSpoke(in: "chat")
    try check(!denials.blocks(send), "The person's next message lets the action be asked again")
    try check(denials.blocks(other), "A message in one chat leaves another chat's denials standing")
    denials.forget(other)
    try check(!denials.blocks(other), "The person's own repeat of a declined pick is asked again")
  }

  private static func standingYeses(_ check: Check) throws {
    typealias Y = StandingYes
    let sites: [String] = (1...25).map { "site\($0).example.com" }
    let kept = Y.capped(sites, forKey: RoutineGrants.sitesKey) as? [String]
    try check(kept?.count == 20 && kept?.first == "site6.example.com" && kept?.last == "site25.example.com",
      "A 21st standing yes of a kind drops the oldest")
    try check((Y.capped(sites, forKey: ProjectEditApprovals.key) as? [String])?.count == 20, "Project edits hold 20 too")
    try check((Y.capped(sites, forKey: SiteRules.key) as? [String])?.count == 25, "A list that is not a standing yes is never cut")
    try check(Y.capped(nil, forKey: RoutineGrants.sitesKey) == nil, "Removing a list still removes it")

    let rules: [String: SiteRule] = ["bank.example.com": .ask]
    let rows = Y.rows(
      sites: ["news.example.com", "pay.bank.example.com"], rules: rules,
      projects: [(id: "p1", name: "Signal")], reads: [(id: "c1", name: "Linear")], commands: .always)
    try check(rows.map(\.title) == [
      "pay.bank.example.com · Routine steps", "news.example.com · Routine steps", "Signal · File edits", "Linear · Reads",
      "This Mac · Commands",
    ], "Every standing yes is one row, where · what, newest site first")
    try check(rows.first?.asksFirst == true && rows[1].asksFirst == false, "Ask first beats allow: a site set to ask shows that it asks")
    func covers(_ rule: SiteRule) -> Bool {
      RoutineGrants.covers(
        decision: .ask, effect: .click, site: "pay.bank.example.com", rule: rule, scheduled: false,
        taskSites: [], alwaysSites: ["pay.bank.example.com"])
    }
    try check(covers(.normal) && !covers(.ask) && !covers(.never), "And that standing yes answers nothing while the rule stands")
    try check(Y.rows(sites: [], rules: [:], projects: [], reads: [], commands: .ask).isEmpty, "Ask every time is not a standing yes")

    let suite: String = "serein.check.standingYes.\(UUID().uuidString)"
    guard let store = UserDefaults(suiteName: suite) else { throw SereinError.invalid("No scratch settings for the standing-yes checks") }
    defer { store.removePersistentDomain(forName: suite) }
    RoutineGrants.allow("news.example.com", defaults: store)
    ProjectEditApprovals.allow("p1", defaults: store)
    store.set(LocalExecution.Mode.always.rawValue, forKey: LocalExecution.key)
    for row in rows where row.kind != .reads { Y.askAgain(row, defaults: store) }
    try check(RoutineGrants.sites(defaults: store).isEmpty && ProjectEditApprovals.all(defaults: store).isEmpty
      && LocalExecution.mode(defaults: store) == .ask, "Ask again takes each yes back")
    try check(!Y.askAgain(Y.Row(kind: .reads, key: "c1", name: "Linear"), defaults: store), "A connection's reads are turned off by the app")
  }

  /// What a Mac step does, as the door reads it, and what is the person's before any level.
  private static func macStepLevel(_ check: Check) throws {
    typealias S = RelayAutonomy.MacStep
    let sendKeys: [S] = [
      S(app: "Mail", kind: "key", key: "Shift-Cmd-D"),
      S(app: "Mail", kind: "key", key: "cmd+shift+d"),
      S(app: "Microsoft Outlook", kind: "key", key: "cmd+return"),
      S(app: "Slack", kind: "key", key: "Cmd-Enter"),
      S(app: "Notes", kind: "key", key: "cmd+keypadenter"),
    ]
    try check(sendKeys.allSatisfy { ApprovalGate.effect(of: $0) == .send },
      "A send shortcut (Shift-Cmd-D, Cmd-Return, Cmd-Enter) is a send in any app")
    try check(ApprovalGate.effect(of: S(app: "Mail", kind: "key", key: "cmd+d")) == .navigate
      && ApprovalGate.effect(of: S(app: "Mail", kind: "key", key: "shift+return")) == .submit,
      "Cmd-D and Shift-Return are not read as send shortcuts")
    try check(ComputerHold.personOnly(kind: "type", role: "AXTextField", label: "Password") == .password
      && ComputerHold.personOnly(kind: "type", role: "AXTextField", label: "Sign-in code") == .code,
      "A password or sign-in code is left for the person before any level is consulted")
  }

  private static func askBeforeWords(_ check: Check) throws {
    try check(ProjectAccess.allCases.map(\.title) == [
      "Ask before edits", "Ask before commands", "Ask before risky commands", "Never ask (full access)",
    ], "A task's permission reads in Ask before words")
    try check(ProjectAccess.allCases.map(\.note) == ["asks before edits", "asks before commands", "asks before risky commands", "never asks"],
      "The chip's note says the same")
    try check(RunPermissionMode.allCases.allSatisfy { $0.detail.hasPrefix("Asks before") || $0.detail.hasPrefix("Never asks") },
      "Every task mode says what it asks before")
    // The words changed; what each choice grants did not.
    try check(ProjectAccess.allCases.map(\.permission) == [.supervised, .supervised, .auto, .fullAccess]
      && ProjectAccess.allCases.map(\.edits) == [false, true, true, true], "The wording changes nothing a choice allows")
  }
}
#endif
