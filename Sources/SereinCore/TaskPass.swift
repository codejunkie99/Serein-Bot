import Foundation

/// A paired app's permission to act, for one task. It covers the sites that task started on.
/// The first action on another site asks. A yes stays on this task. Ending the task ends the pass.
public struct TaskPass: Equatable, Sendable {
  public var taskID: String
  public var sites: Set<String>
  public var ended: Bool

  public init(taskID: String, sites: Set<String> = [], ended: Bool = false) {
    self.taskID = taskID
    self.sites = sites
    self.ended = ended
  }

  public static func begin(taskID: String) -> TaskPass {
    TaskPass(taskID: taskID)
  }

  /// The host of a URL or a bare site. Empty when there is nothing to compare.
  public static func host(_ site: String) -> String {
    let trimmed = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return "" }
    if let host = URL(string: trimmed)?.host, !host.isEmpty { return host }
    if trimmed.contains("://") { return "" }
    return trimmed.split(separator: "/").first.map(String.init) ?? ""
  }

  /// Records a site the task opened. An ended pass records nothing.
  public mutating func started(on site: String) {
    let host = Self.host(site)
    guard !ended, !host.isEmpty else { return }
    sites.insert(host)
  }

  /// A person's yes for this site, on this task only. An ended pass keeps its old sites and adds none.
  /// Replaces the list with the hosts a person typed. Empty hosts are dropped.
  public mutating func replace(with hosts: [String]) {
    guard !ended else { return }
    sites = Set(hosts.map(Self.host).filter { !$0.isEmpty })
  }

  public mutating func allow(site: String) {
    let host = Self.host(site)
    guard !ended, !host.isEmpty else { return }
    sites.insert(host)
  }

  public mutating func end() { ended = true }

  /// True when this action is outside the sites the task already has.
  /// An ended pass asks for every site, including one it started on.
  public func needsSiteAsk(site: String?) -> Bool {
    needsSiteAsk(site: site, honorEnded: true)
  }

  /// `honorEnded` false is the dropped guard: an ended pass keeps its old sites.
  @_spi(SereinReview)
  public func needsSiteAsk(site: String?, honorEnded: Bool) -> Bool {
    if honorEnded && ended { return true }
    guard let site else { return false }
    let host = Self.host(site)
    guard !host.isEmpty else { return false }
    return !sites.contains(host)
  }

  public enum SiteAdmit: Equatable, Sendable { case already, ask }

  /// The first site asks before it is recorded.
  public static func admit(pass: inout TaskPass, site: String) -> SiteAdmit {
    if !pass.needsSiteAsk(site: site) { return .already }
    return .ask
  }

  /// The dropped guard: an empty list records the site and does not ask.
  /// Production `admit` never does this.
  @_spi(SereinReview)
  public static func recordFirstSiteWithoutAsking(pass: inout TaskPass, site: String) -> Bool {
    guard pass.sites.isEmpty else { return false }
    pass.started(on: site)
    return !pass.sites.isEmpty
  }

  /// A merge, payment, send or other consequential effect asks even on a site this pass covers.
  public func decide(site: String?, effect: ApprovalGate.Effect, autopilot: Bool) -> RelayAutonomy.Decision {
    decide(site: site, effect: effect, autopilot: autopilot, honorEnded: true, respectMustAsk: true, honorSites: true)
  }

  /// `respectMustAsk` false lets that effect run on a covered site.
  /// `honorSites` false lets a new site run. `honorEnded` false lets an ended pass keep working.
  @_spi(SereinReview)
  public func decide(
    site: String?, effect: ApprovalGate.Effect, autopilot: Bool,
    honorEnded: Bool, respectMustAsk: Bool, honorSites: Bool
  ) -> RelayAutonomy.Decision {
    if respectMustAsk && ApprovalGate.mustAsk.contains(effect) { return .ask }
    if honorSites && needsSiteAsk(site: site, honorEnded: honorEnded) { return .ask }
    if !autopilot { return .ask }
    return .auto
  }
}
