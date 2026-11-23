import Foundation

/// Standing yeses for routine steps on the web (a click, typing, moving between pages): for the
/// rest of one task, or always on one site. They only ever stand in for a question Autopilot
/// would also skip: never for an effect in `ApprovalGate.mustAsk` or `personOnly` (sending,
/// paying, deleting, submitting, filling, booking, sign-in changes, uploads, settings…), never in
/// a run nobody watches unless the person's own words cover the step (`covered`,
/// UnattendedAuthority), never on a site the person set to Ask every step or Never, and never over a
/// refusal (a password, card or code field). The always-on sites live in GateSettings, where the
/// agent cannot write, and Settings › Privacy lists them with Remove. Pure, so it is checked.
public enum RoutineGrants {
  public static let sitesKey = "serein.routineSites"

  /// An effect a standing yes may cover: one that is not a hard stop.
  public static func qualifies(_ effect: ApprovalGate.Effect) -> Bool {
    !ApprovalGate.mustAsk.contains(effect) && !ApprovalGate.personOnly.contains(effect)
  }

  /// Whether a step that would ask goes ahead on a standing yes: the decision is a question, the
  /// effect qualifies, the run is the person's, the site's rule is Normal, and the site was allowed
  /// for this task or always.
  public static func covers(
    decision: RelayAutonomy.Decision, effect: ApprovalGate.Effect, site: String?, rule: SiteRule, scheduled: Bool,
    covered: Bool = false, taskSites: Set<String>, alwaysSites: [String]
  ) -> Bool {
    guard decision == .ask, qualifies(effect), !scheduled || (covered && UnattendedAuthority.passive.contains(effect)), !UnattendedAuthority.alwaysAsks.contains(effect),
      rule == .normal, let site, !site.isEmpty
    else { return false }
    return taskSites.contains(site) || alwaysSites.contains(site)
  }

  /// Whether a standing yes may answer for a step at all: only in a turn the person started. It
  /// never stands in for anyone in a turn nobody typed (a schedule, a watch, a link delivery, a
  /// light ask, a paired app, a check-in, a hand-off's result or a task's report). `relayTurn` is
  /// Serein's own turn when the step is in Serein's own task (nil for a run's task); `initiator`
  /// is what started the run that holds the task (nil: the person, from a composer); and
  /// `fromPersonTurn` says that Serein started (and last steered) that run in the person's own
  /// turn. A hand-off target, another assistant speaking first, and every scheduled, watch,
  /// webhook or ask run never stand.
  public static func standsIn(relayTurn: Admission.Turn?, initiator: AgentHistoryRun.Initiator?, fromPersonTurn: Bool) -> Bool {
    if let relayTurn { return relayTurn == .person }
    switch initiator {
    case nil: return true
    case .delegated?: return fromPersonTurn
    case .relay?, .scheduled?, .watch?, .webhook?, .handoff?, .ask?: return false
    }
  }

  public static func sites(defaults: any SettingsStore = GateSettings.shared) -> [String] {
    defaults.stringArray(forKey: sitesKey) ?? []
  }
  public static func allow(_ site: String, defaults: any SettingsStore = GateSettings.shared) {
    guard !site.isEmpty, !sites(defaults: defaults).contains(site) else { return }
    defaults.set(sites(defaults: defaults) + [site], forKey: sitesKey)
  }
  public static func revoke(_ site: String, defaults: any SettingsStore = GateSettings.shared) {
    defaults.set(sites(defaults: defaults).filter { $0 != site }, forKey: sitesKey)
  }
}
