import Foundation

/// Full auto fills and pays (owner, 2026-11-26): Serein fills a secret field from what the person
/// saved, and presses pay, with no card. It asks only when nothing is saved for the site, or when a
/// rule the person typed says to ask. Pure: the app reads values from Keychain and fills them at
/// the boundary, so the model never sees one, and this type never holds one.
///
/// Origin rule: a saved item fills only on the exact origin it was saved for (`sameSite`).
/// Payee rule: a pay or a card fill goes only to a site the person named in their own words (`pay`).
public enum FillGuard {
  /// One saved sign-in, code, key or card, never its value.
  public struct Item: Equatable, Sendable {
    public let id: String
    /// What the receipt names: a sign-in's user name, or a key's or card's name.
    public let name: String
    public let kind: SecureCard.Kind
    /// The origins it was saved for: a sign-in's own, or https://<host> for each key or card host.
    public let origins: [String]
    public init(id: String, name: String, kind: SecureCard.Kind, origins: [String]) {
      self.id = id
      self.name = name
      self.kind = kind
      self.origins = origins
    }
  }

  /// A secret field `SecureCard.admit` let through, and the top page origin WebKit read for it.
  /// Only `target(_:)` makes one, so no page text or tool argument can name where a fill goes.
  public struct Target: Equatable, Sendable {
    public let kind: SecureCard.Kind
    public let origin: String
    fileprivate init(kind: SecureCard.Kind, origin: String) {
      self.kind = kind
      self.origin = origin
    }
  }
  public static func target(_ field: SecureCard.Field, loopback: Bool = false) -> Target? {
    guard case .card(let kind) = SecureCard.admit(field, loopback: loopback) else { return nil }
    return Target(kind: kind, origin: field.topOrigin)
  }

  /// The person's own words for one chat: the sites they named and the rules in force. Only
  /// `PersonSaid` builds one, from what the person typed; never from a page, a bot's reply, a file
  /// or mail, even when that text quotes them.
  public struct PersonWords: Equatable, Sendable {
    /// Hosts in lower case, without a leading www.
    let sites: Set<String>
    /// Each rule's text and quote, as `TypedConsent.normalized` reads them.
    let rules: [String]
    /// The rules could not be read, so every fill and pay asks.
    let rulesUnread: Bool
    init(sites: Set<String>, rules: [String], rulesUnread: Bool = false) {
      self.sites = sites
      self.rules = rules
      self.rulesUnread = rulesUnread
    }
  }

  public enum FillVerdict: Equatable, Sendable {
    case fill(Item)
    /// Nothing saved for this origin, or a rule the person typed asks: the secure card asks once.
    case ask
    case refused(String)
  }
  public enum PayVerdict: Equatable, Sendable {
    case pay
    /// A rule the person typed asks before paying: the person step's card asks.
    case ask
    case refused(String)
  }

  public static func fill(_ target: Target, saved: [Item], person: PersonWords) -> FillVerdict {
    if target.kind == .card {
      switch pay(payee: target.origin, person: person) {
      case .refused(let why): return .refused(why)
      case .ask: return .ask
      case .pay: break
      }
    } else if person.asks(topic(target.kind)) {
      return .ask
    }
    let item = saved.first { $0.kind == target.kind && $0.origins.contains { sameSite(saved: $0, page: target.origin) } }
    return item.map(FillVerdict.fill) ?? .ask
  }

  /// `payee`: the top page origin WebKit read for the tab that pays.
  public static func pay(payee origin: String, person: PersonWords) -> PayVerdict {
    if person.asks(.pay) { return .ask }
    guard let payee = CredentialOrigin.normalize(origin).flatMap({ URL(string: $0)?.host }).map(bare) else {
      return .refused(notSecure)
    }
    guard person.sites.contains(where: { payee == $0 || payee.hasSuffix("." + $0) }) else {
      return .refused(notNamed(payee))
    }
    return .pay
  }

  /// The origin rule: scheme, host and port equal, HTTPS (plain HTTP only on loopback, as
  /// `CredentialOrigin` allows). A leading www. is the one equivalence. Subdomains differ, and hosts
  /// compare in WebKit's ASCII form, so a lookalike is another origin.
  public static func sameSite(saved: String, page: String) -> Bool {
    guard let a = CredentialOrigin.normalize(saved).flatMap(URL.init(string:)),
      let b = CredentialOrigin.normalize(page).flatMap(URL.init(string:))
    else { return false }
    return a.scheme == b.scheme && a.port == b.port && bare(a.host ?? "") == bare(b.host ?? "") && !bare(a.host ?? "").isEmpty
  }

  public static let notSecure =
    "Blocked: this page is not on a secure connection, so Serein does not pay or enter a card there. Route: carry on with the parts that need no payment."
  public static func notNamed(_ host: String) -> String {
    "Blocked: the person never named \(host) in their own words, so Serein does not pay or enter a card there. Route: tell the person which site the payment is for and carry on with the rest; once they name the site in a message, try again."
  }

  // MARK: receipts

  /// Undo entries of fills: Undo clears the field while its page is unchanged.
  public static let undoPrefix = "fill:"
  /// After a fill lands: the site and which saved item, never its value, and Undo.
  public static func filled(_ item: Item, host: String, entry: String) -> Receipt {
    let site = String(host.prefix(60))
    return Receipt(
      kind: .filled, line: "Done. I filled your saved \(what(item.kind)) on \(site).",
      card: .banner(title: site, detail: "From \(item.name), saved for this site.", action: nil),
      undo: UndoToken(entry: undoPrefix + entry, kind: .filled))
  }
  /// After a pay press lands. The amount is the page's own reading of the button.
  public static func paid(amount: String, host: String) -> Receipt {
    let site = String(host.prefix(60))
    return Receipt(
      kind: .paid, line: "Done. I paid \(String(amount.prefix(24))) on \(site).",
      card: .banner(title: site, detail: "You named \(site) in this chat. To cancel, use the site's own order page.", action: nil))
  }

  /// The tool's answer after a fill from saved data: what went in, by name, never its value.
  public static func filledFields(_ item: Item, host: String) -> [String: String] {
    let who = item.kind == .password || item.kind == .code ? " for the user name \(item.name)" : " (\(item.name))"
    return [
      "result": "filled",
      "next": "Serein filled the \(what(item.kind)) saved for \(host)\(who); you never see it. Read the page again, then carry on.",
    ]
  }
  public static func paidFields(amount: String, host: String) -> [String: String] {
    ["result": "done", "next": "Serein pressed pay for \(amount) on \(host). Read the page again, then carry on."]
  }

  // MARK: words

  enum Topic { case pay, signIn, key }
  static func topic(_ kind: SecureCard.Kind) -> Topic {
    switch kind {
    case .password, .code: return .signIn
    case .key: return .key
    case .card: return .pay
    }
  }
  static let askWords = ["ask", "check with me", "confirm with me", "wait for me"]
  static let topicStems: [Topic: [String]] = [
    .pay: ["pay", "buy", "bought", "purchas", "checkout", "check out", "order", "card", "bank", "charg", "spend"],
    .signIn: ["sign in", "signing in", "log in", "logging in", "login", "password", "passcode"],
    .key: ["key", "token"],
  ]

  /// Sites named in typed words: domain names with or without a scheme, lower case, www. dropped.
  static func sites(in text: String) -> Set<String> {
    let pattern = #"(?i)(?<![a-z0-9.-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}(?![a-z0-9-])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return Set(regex.matches(in: text, range: range).compactMap { match in
      Range(match.range, in: text).flatMap { SecretVault.host(String(text[$0])) }.map(bare)
    })
  }
  static func bare(_ host: String) -> String {
    let lower = host.lowercased()
    return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
  }
  static func what(_ kind: SecureCard.Kind) -> String {
    switch kind {
    case .password: return "sign-in"
    case .code: return "sign-in code"
    case .key: return "key"
    case .card: return "card"
    }
  }
}

extension FillGuard.PersonWords {
  /// A rule asks for `topic` when it holds an ask word and one of the topic's words. A rule only
  /// ever adds an ask, so honoring a rule from any source is safe.
  func asks(_ topic: FillGuard.Topic) -> Bool {
    if rulesUnread { return true }
    let stems = FillGuard.topicStems[topic] ?? []
    return rules.contains { rule in
      let words = rule.split(separator: " ")
      func has(_ phrase: String) -> Bool {
        phrase.contains(" ") ? rule.contains(" \(phrase) ") : words.contains { $0.hasPrefix(phrase) }
      }
      return FillGuard.askWords.contains(where: has) && stems.contains(where: has)
    }
  }
}

/// What the person typed into each chat, kept in memory for the app's life: the only source of
/// `FillGuard.PersonWords`. Written by the person's own sends (the composer's draft in
/// `Agent.send` and its queue, Serein's turn the person started) and copied to a task Serein
/// delegates in that turn. Host text (a card's follow-up, a hand-off, a report) never writes here.
public final class PersonSaid: @unchecked Sendable {
  public static let shared = PersonSaid()
  /// Messages kept per chat; the oldest go first.
  static let cap = 40
  struct Said {
    var words: [String] = []
    var sites: Set<String> = []
  }
  private let lock = NSLock()
  private var byThread: [String: Said] = [:]
  public init() {}

  /// `site`: the host of the tab the person's message carried.
  public func said(_ words: String, site: String? = nil, thread: String) {
    guard !thread.isEmpty else { return }
    lock.withLock {
      var said = byThread[thread] ?? Said()
      if !words.isEmpty { said.words = Array((said.words + [words]).suffix(Self.cap)) }
      if let site, !site.isEmpty { said.sites.insert(FillGuard.bare(site)) }
      byThread[thread] = said
    }
  }
  /// A task Serein started in the person's turn stands on that turn's words.
  public func inherit(_ child: String, from parent: String) {
    lock.withLock {
      guard let from = byThread[parent], child != parent else { return }
      var said = byThread[child] ?? Said()
      said.words = Array((said.words + from.words).suffix(Self.cap))
      said.sites.formUnion(from.sites)
      byThread[child] = said
    }
  }
  public func forget(thread: String) { lock.withLock { byThread[thread] = nil } }

  /// `rules` nil: they could not be read.
  public func words(thread: String?, rules: [MemoryRecord]?) -> FillGuard.PersonWords {
    let said = thread.flatMap { t in lock.withLock { byThread[t] } } ?? Said()
    guard let rules else { return FillGuard.PersonWords(sites: [], rules: [], rulesUnread: true) }
    let ruled = rules.filter { $0.kind == .rule }.flatMap { [$0.text, $0.quote ?? ""] }.map(TypedConsent.normalized)
    let named = said.words.reduce(into: said.sites) { $0.formUnion(FillGuard.sites(in: $1)) }
    return FillGuard.PersonWords(sites: named, rules: ruled)
  }
}
