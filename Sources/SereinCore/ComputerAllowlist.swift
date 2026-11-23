import Foundation

/// One computer's list of sites (Settings › Serein's computer › Only these sites). On a computer
/// whose traffic goes through Serein's proxy, `only` makes the proxy refuse every host that is not
/// on the list (ComputerNetworkPolicy.hostRefusal), on top of the person's site rules, the
/// assistant's Never sites and the private ranges, which still refuse a listed host. The same
/// shape holds a hosted computer's provider-internet list (HostedSettings.providerList), which the
/// provider enforces. Turning the list off, or adding a site while it is on, lets the computer
/// reach more: that is a Widening card (ApprovalGate `widening`, person-only). Turning it on, or
/// removing a site, only narrows and needs none.
public struct ComputerAllowlist: Codable, Equatable, Sendable {
  public var only: Bool
  public var sites: [String]
  /// Sites one computer's own list may hold.
  public static let maxSites = 200

  public init(only: Bool = false, sites: [String] = []) {
    self.only = only
    self.sites = HostedNetwork.clean(sites, limit: Self.maxSites)
  }
  enum CodingKeys: String, CodingKey { case only, sites }
  /// A record from disk keeps only valid sites; a missing switch is off.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      only: try c.decodeIfPresent(Bool.self, forKey: .only) ?? false,
      sites: try c.decodeIfPresent([String].self, forKey: .sites) ?? [])
  }

  /// One change from Settings.
  public enum Edit: Equatable, Sendable {
    case only(Bool)
    case add(String)
    case remove(String)
  }

  /// Whether a host may be reached: anything while the list is off; with it on, a host named
  /// exactly, or one under a `*.name` entry (`name` itself or a name ending in `.name`, so
  /// `evilgithub.com` is never under `*.github.com`). An address literal is never on the list.
  public func allows(host: String) -> Bool {
    guard only else { return true }
    let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    return sites.contains { Self.matches(host: name, entry: $0) }
  }
  public static func matches(host: String, entry: String) -> Bool {
    guard !host.isEmpty else { return false }
    if entry.hasPrefix("*.") {
      let base = String(entry.dropFirst(2))
      return host == base || host.hasSuffix("." + base)
    }
    return host == entry
  }

  /// Why `raw` cannot be added, or nil.
  public func addProblem(_ raw: String, limit: Int = maxSites) -> String? {
    guard let site = HostedNetwork.allowEntry(raw) else {
      return "Not a site. Use a name such as example.com, or *.example.com for every name under it. A name in another script goes in its xn-- form."
    }
    if sites.contains(site) { return "\(site) is on the list already." }
    if sites.count >= limit { return "The list is full: at most \(limit) sites." }
    return nil
  }
  /// The list after `edit`; nil when it cannot be made (a site that is not one, or a full list).
  public func applying(_ edit: Edit, limit: Int = maxSites) -> ComputerAllowlist? {
    var next = self
    switch edit {
    case .only(let on): next.only = on
    case .add(let raw):
      guard addProblem(raw, limit: limit) == nil, let site = HostedNetwork.allowEntry(raw) else { return nil }
      next.sites.append(site)
    case .remove(let site): next.sites.removeAll { $0 == site }
    }
    return next
  }
  /// Whether `after` lets the computer reach something this list does not: the switch turned
  /// off, or, with it on before and after, a site that was not there. Turning it on narrows
  /// whatever the list holds.
  public func widens(to after: ComputerAllowlist) -> Bool {
    if only && !after.only { return true }
    guard only, after.only else { return false }
    return !Set(after.sites).isSubset(of: Set(sites))
  }

  /// The proxy's refusal of a host that is not on the list.
  public static func refusal(host: String, assistant: String?) -> String {
    "\(host) is not on the sites \(assistant ?? "this assistant")'s computer may reach (Only these sites is on in Settings › Serein's computer). Nothing was opened. Do not try it again; tell the person it is not on the list."
  }

  /// The Widening card's words for one change, or nil when the change narrows (no card).
  /// `provider` names the hosted provider whose own internet the list holds; nil for Serein's proxy.
  public func card(_ edit: Edit, assistant: String, provider: String? = nil, limit: Int = maxSites)
    -> (title: String, detail: String)?
  {
    guard let after = applying(edit, limit: limit), widens(to: after) else { return nil }
    switch edit {
    case .only:
      let kept = " The \(sites.count) site\(sites.count == 1 ? "" : "s") on the list stay for when you turn it on again."
      let reach = provider.map {
        " With Only these sites off, it gets \($0)'s own internet. \(HostedCard.openLine) Your site rules and \(assistant)'s Never sites don't apply there."
      } ?? " With Only these sites off, it may reach any site but your Never sites and \(assistant)'s, and never this Mac or your network."
      return ("Let \(assistant)'s computer reach every site?", ApprovalGate.askLine(.widening) + reach + kept)
    case .add(let raw):
      let site = HostedNetwork.allowEntry(raw) ?? raw
      let under = site.hasPrefix("*.") ? " and every name under \(site.dropFirst(2))" : ""
      let rules: String = provider.map { " on \($0)'s own internet, where your site rules don't apply." } ?? "; your site rules still apply there."
      let detail: String = ApprovalGate.askLine(.widening) + " \(site) is added to the sites it may reach\(under)" + rules
      return ("Let \(assistant)'s computer reach \(site)?", detail)
    case .remove:
      return nil
    }
  }
}
