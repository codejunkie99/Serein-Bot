import Foundation

/// A site Serein stays signed in to for its own later tasks, because the person ticked Keep Serein
/// signed in at Hand back. Its cookies are that registrable site's only, in a website data store
/// Serein made for it (TaskStores), never the person's own store.
public struct KeptSignIn: Equatable, Sendable {
  /// The registrable site, such as example.com or example.co.uk.
  public let site: String
  /// The website data store that holds its cookies.
  public let store: UUID
  /// When a task last used it, or when it was kept.
  public var lastUsed: Date
  public init(site: String, store: UUID, lastUsed: Date) {
    self.site = site
    self.store = store
    self.lastUsed = lastUsed
  }
  /// Unused for `KeptSignIns.lifetime`: it has ended.
  public func expired(now: Date) -> Bool { now.timeIntervalSince(lastUsed) >= KeptSignIns.lifetime }
}

/// The kept sign-ins by site, in GateSettings (`key`): each one lets later tasks act signed in, so
/// it loosens a gate. Only the person adds one (Hand back); Sign out, Sign out of all and 30 days
/// unused end one. It is not an `AgentSetting`, so no agent tool reads or writes the list. While
/// that file cannot be read, nothing is kept. The key was never in UserDefaults, so it is not in
/// `GateKeys.all` and no migration can bring a value in from there.
public enum KeptSignIns {
  public static let key = "serein.keptSignIns"
  /// A kept sign-in unused this long ends.
  public static let lifetime: TimeInterval = 30 * 24 * 60 * 60
  /// Hosting names whose subdomains belong to different people (alice.github.io, mallory.github.io):
  /// one "site" there would be everyone's, so none of them is ever kept, named or used.
  public static let sharedHosts: Set<String> = [
    "github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "herokuapp.com",
    "blogspot.com", "appspot.com", "web.app", "firebaseapp.com", "azurewebsites.net", "cloudfront.net",
    "amazonaws.com", "myshopify.com", "onrender.com", "fly.dev", "glitch.me", "ngrok.io", "ngrok-free.app",
    "wixsite.com",
  ]

  /// The site a sign-in is kept under: the registrable part of an HTTPS address's host
  /// ("https://login.Example.co.uk/x" is "example.co.uk"). nil for plain HTTP, an IP address and a
  /// private or single-label host.
  public static func site(_ address: String) -> String? {
    guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme?.lowercased() == "https",
      let host = url.host.flatMap({ SitePolicy.site($0) }), !SitePolicy.isPrivate(host),
      !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." })
    else { return nil }
    let site: String = CookieSites.site(for: host)
    guard !sharedHosts.contains(site) else { return nil }
    // A public suffix itself ("co.uk") names no one's site.
    let labels: [Substring] = site.split(separator: ".")
    if labels.count == 2, CookieSites.compoundSuffixes.contains(String(labels[0])) { return nil }
    return site
  }

  /// A site as a request names it ("example.com", "https://www.example.com/x"): its kept-under site.
  public static func named(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return site(trimmed.contains("://") ? trimmed : "https://" + trimmed)
  }

  /// Whether a cookie set for `domain` (".login.example.com") is `site`'s.
  public static func covers(domain: String, site: String) -> Bool { CookieSites.site(for: domain) == site }

  /// Whether a cookie set for `domain` is one a page on `host` receives: the very host, or a parent
  /// domain of it. Only those are kept from the page the person signed in on.
  public static func sent(domain: String, to host: String) -> Bool {
    var cookieDomain: String = domain.lowercased()
    while cookieDomain.hasPrefix(".") { cookieDomain.removeFirst() }
    let page: String = SitePolicy.host(host)
    guard !cookieDomain.isEmpty else { return false }
    return page == cookieDomain || page.hasSuffix("." + cookieDomain)
  }

  /// Every listed sign-in, ended ones too, by site. None while the file cannot be read.
  public static func listed(defaults: any SettingsStore = GateSettings.shared) -> [KeptSignIn] {
    let map: [String: Any] = defaults.dictionary(forKey: key) ?? [:]
    var found: [KeptSignIn] = []
    for (raw, value) in map {
      guard let entry = value as? [String: Any], named(raw) == raw, let id = entry["store"] as? String,
        let store = UUID(uuidString: id), let used = entry["used"] as? Double
      else { continue }
      found.append(KeptSignIn(site: raw, store: store, lastUsed: Date(timeIntervalSince1970: used)))
    }
    return found.sorted { $0.site < $1.site }
  }

  /// The sign-ins in force: listed and used within `lifetime`.
  public static func all(now: Date = Date(), defaults: any SettingsStore = GateSettings.shared) -> [KeptSignIn] {
    listed(defaults: defaults).filter { !$0.expired(now: now) }
  }

  /// The site's sign-in in force, if any.
  public static func kept(_ site: String, now: Date = Date(), defaults: any SettingsStore = GateSettings.shared)
    -> KeptSignIn?
  {
    all(now: now, defaults: defaults).first { $0.site == site }
  }

  /// Lists `signIn`, in place of the site's earlier one. False when it was not saved (it then
  /// holds for this launch only, as every GateSettings change does).
  @discardableResult public static func save(_ signIn: KeptSignIn, defaults: any SettingsStore = GateSettings.shared)
    -> Bool
  {
    var map = defaults.dictionary(forKey: key) ?? [:]
    map[signIn.site] = ["store": signIn.store.uuidString, "used": signIn.lastUsed.timeIntervalSince1970]
    return write(map, defaults)
  }

  /// A task used the site's sign-in now: its 30 days start again.
  public static func touch(_ site: String, now: Date = Date(), defaults: any SettingsStore = GateSettings.shared) {
    guard var signIn = listed(defaults: defaults).first(where: { $0.site == site }) else { return }
    signIn.lastUsed = now
    save(signIn, defaults: defaults)
  }

  /// Takes these sites off the list. False when the change was not saved.
  @discardableResult public static func remove(_ sites: Set<String>, defaults: any SettingsStore = GateSettings.shared)
    -> Bool
  {
    var map = defaults.dictionary(forKey: key) ?? [:]
    for site in sites { map[site] = nil }
    return write(map.isEmpty ? nil : map, defaults)
  }

  private static func write(_ map: [String: Any]?, _ defaults: any SettingsStore) -> Bool {
    if let gates = defaults as? GateSettings { return gates.update(map, forKey: key) }
    defaults.set(map, forKey: key)
    return true
  }
}

/// How a task's use of a kept sign-in on a site is decided (`BrowserModel.useKeptSignIn`), once per
/// task and site. At Allow all no window waits: the person's yes comes on this call's person_step
/// card in the chat.
public enum KeptSignInAsk: Equatable, Sendable {
  /// The person said yes on this exact call's person_step card: use it.
  case use
  /// Asked in this task already, with no yes: the page opens signed out.
  case signedOut
  /// At Allow all, the first time: the call stops once with the person_step route.
  case personStep
  /// Below Allow all, or with nobody watching: the card at the step, or the creation card's yes.
  case card

  public static func decide(allowsAll: Bool, granted: Bool, askedBefore: Bool) -> KeptSignInAsk {
    if allowsAll && granted { return .use }
    if askedBefore { return .signedOut }
    return allowsAll ? .personStep : .card
  }
  public static func route(_ site: String) -> Blocked {
    Blocked(
      "this uses the person's kept sign-in on \(site), which only they allow",
      routes: .init(
        "call person_step with kind confirm, this tool's name and these same arguments, carry on with every other part, and make this same call again once the person says yes",
        "make this same call again now to open the page signed out"))
  }
}
