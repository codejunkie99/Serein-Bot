import Foundation

/// A person's lasting rule for one site, for every task, schedule and alert. Rules only make
/// Serein stricter: there is no rule that skips a question, and send, pay, post and delete ask
/// whatever the rule.
public enum SiteRule: String, CaseIterable, Sendable {
  /// The default; never stored.
  case normal
  /// Every step on the site asks, even a scroll or a click Autopilot would run.
  case ask
  /// Serein does not open, read or act on the site, and leaves its tabs out of page context.
  case never

  public var label: String {
    switch self {
    case .normal: return "Normal"
    case .ask: return "Ask every step"
    case .never: return "Never"
    }
  }

  fileprivate var strictness: Int {
    switch self {
    case .normal: return 0
    case .ask: return 1
    case .never: return 2
    }
  }
}

/// Site rules, stored by site in GateSettings: a rule taken away loosens a gate. They are not an
/// `AgentSetting`, so `settings_get` and `settings_set` can neither list nor change them. While
/// that file cannot be read, every site reads as Never: agents work on no site until it reads again.
/// A rule covers its site and every subdomain (`SitePolicy.matches`), and is read again for each
/// action, so a change applies to the next one.
public enum SiteRules {
  public static let key = "serein.siteRules"

  /// The site a rule is stored and compared under: "https://www.Bank.example.com:8443/x" is
  /// "bank.example.com". A host `SitePolicy` will not name (an underscore) is still compared,
  /// so an odd host cannot step around a rule.
  public static func site(_ input: String) -> String? {
    if let site = SitePolicy.site(input) { return site }
    let host = SitePolicy.host(URL(string: input)?.host ?? "").withoutWWW
    return host.isEmpty ? nil : host
  }

  private static let lock = NSLock()
  private static var memo: [String: SiteRule]?
  private static var watcher: NSObjectProtocol?

  /// The rules the person set, by site. Read per console message, tab row and navigation, so
  /// the shared store's parse is kept until GateSettings changes.
  public static func all(defaults: any SettingsStore = GateSettings.shared) -> [String: SiteRule] {
    guard defaults === GateSettings.shared else { return parse(defaults) }
    lock.lock(); defer { lock.unlock() }
    if let memo { return memo }
    if watcher == nil {
      watcher = NotificationCenter.default.addObserver(forName: GateSettings.changed, object: nil, queue: nil) { _ in
        lock.lock(); memo = nil; lock.unlock()
      }
    }
    let parsed = parse(defaults); memo = parsed; return parsed
  }

  /// Unknown values and Normal are dropped.
  private static func parse(_ defaults: any SettingsStore) -> [String: SiteRule] {
    var rules: [String: SiteRule] = [:]
    for (raw, value) in defaults.dictionary(forKey: key) ?? [:] {
      guard let site = SitePolicy.site(raw), let value = value as? String, let rule = SiteRule(rawValue: value),
        rule != .normal
      else { continue }
      if rule.strictness > (rules[site]?.strictness ?? 0) { rules[site] = rule }
    }
    return rules
  }

  /// Normal removes the site's rule. An input that names no site changes nothing.
  public static func set(_ rule: SiteRule, for input: String, defaults: any SettingsStore = GateSettings.shared) {
    guard let site = SitePolicy.site(input) else { return }
    var rules = all(defaults: defaults)
    rules[site] = rule == .normal ? nil : rule
    defaults.set(rules.mapValues(\.rawValue), forKey: key)
    lock.lock(); memo = nil; lock.unlock()
  }

  /// The strictest rule that covers this address or bare host; Normal when none does.
  public static func rule(for address: String?, defaults: any SettingsStore = GateSettings.shared) -> SiteRule {
    guard let address, let site = Self.site(address) else { return .normal }
    if (defaults as? GateSettings)?.unreadable == true { return .never }
    return all(defaults: defaults).filter { SitePolicy.matches(host: site, site: $0.key) }.values
      .max { $0.strictness < $1.strictness } ?? .normal
  }

  /// Person-facing, wherever a rule stopped something (a step, a schedule, an alert, a chip).
  /// `verb` is "read" for a tab the person already has open.
  public static func personLine(_ site: String, verb: String = "open") -> String {
    "Serein doesn’t \(verb) \(site) (your rule in Settings › Privacy)."
  }

  /// Model-facing and shown in the task: the agent learns not to try the site again.
  public static func refusal(_ address: String) -> String {
    "Serein doesn’t open \(Self.site(address) ?? "this site") (the person's rule for this site). Nothing was done. Do not try this site again; finish and tell the person it is blocked by their rule."
  }

  /// Model-facing: a redirect onto a Never site came after the action ran, so the action's
  /// effect is not denied.
  public static func redirectRefusal(_ address: String) -> String { "The page tried to open \(site(address) ?? "a site") and Serein did not load it (the person's rule for this site). Anything before that was done; the tab stayed on its page. Do not try this site again; finish and tell the person it is blocked by their rule." }

  /// Throws the refusal when a rule sets this address's site to Never.
  public static func check(_ address: String?, defaults: any SettingsStore = GateSettings.shared) throws {
    guard let address, rule(for: address, defaults: defaults) == .never else { return }
    throw SiteRuleRefusal(site: Self.site(address) ?? address)
  }
}

/// A refusal by the person's site rule, typed so a task can show it as a rule (not a failure)
/// and an unattended run is recorded as blocked rather than counted toward its pause.
public struct SiteRuleRefusal: LocalizedError, Sendable {
  public let site: String
  public var redirect = false
  /// The assistant whose own Never sites refused it (AssistantScope); nil is the person's rule.
  public var assistant: String?
  public init(site: String, redirect: Bool = false, assistant: String? = nil) {
    self.site = site
    self.redirect = redirect
    self.assistant = assistant
  }
  public var errorDescription: String? {
    if let assistant {
      return redirect
        ? "The page tried to open \(site) and Serein did not load it (a site turned off for \(assistant)). Anything before that was done; the tab stayed on its page. Do not try this site again; tell the person it is turned off for \(assistant)."
        : AssistantScope.siteRefusal(name: assistant, address: site)
    }
    return redirect ? SiteRules.redirectRefusal(site) : SiteRules.refusal(site)
  }
}
