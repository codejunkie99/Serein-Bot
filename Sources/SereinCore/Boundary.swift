import Foundation

/// A tool result that says no to one step and lists routes. It reaches the model as a normal
/// result, never as `isError` (R17): the tool socket answers a thrown `Blocked` with its text.
public struct Blocked: Error, Sendable, Equatable, LocalizedError {
  public struct Routes: Sendable, Equatable {
    public let first: String
    public let rest: [String]
    public init(_ first: String, _ rest: String...) {
      self.first = first
      self.rest = rest
    }
  }
  public let what: String
  public let routes: Routes
  /// A line that follows the routes (siteNever's "Do not open this site.").
  public let after: String?
  public init(_ what: String, routes: Routes, after: String? = nil) {
    self.what = what
    self.routes = routes
    self.after = after
  }

  /// "Blocked: {what}. Routes: {first}; or {rest}." Fixed text, no page text.
  public var text: String {
    let routes = ([routes.first] + routes.rest).joined(separator: "; or ")
    return "Blocked: \(what). Routes: \(routes)." + (after.map { " " + $0 } ?? "")
  }
  public var errorDescription: String? { text }
}

/// The few places code says no. Everything else runs (reviews/PRINCIPLE.md).
public enum Boundary: Sendable, Equatable {
  /// A field only the person fills (AXSecureTextField, a password input).
  case secret
  /// A CAPTCHA or "are you human": the takeover card opens on its own.
  case botCheck
  /// The press pays; the route is person_step pay on this button (R1).
  case pay(ref: String)
  /// Serein's stores, keychains, password manager sockets and apps.
  case privateStore
  /// A code-running app driven outside mac_run (R29).
  case codeRunner
  /// The person set this site to Never (SiteRules).
  case siteNever
  /// The person set this site to Ask every step: a card per changing step, at every level (R18).
  case siteAsk
  /// A changed SSH host key blocks that host only (R21).
  case hostKey(host: String)

  /// nil for siteAsk, which carries on behind a card instead.
  public var blocked: Blocked? {
    switch self {
    case .secret:
      return Blocked(
        "this field takes a value only the person has",
        routes: .init("call secure_card on it and carry on with the rest", "use a sign-in Serein already keeps for this site"))
    case .botCheck:
      return Blocked(
        "this page checks that a person is there. Serein opened a card for the person",
        routes: .init("carry on with every other part", "reach the same result on another site or without signing in"))
    case .pay:
      return Blocked(
        "this press pays",
        routes: .init(
          "call person_step with kind pay on this button, and Serein shows the person the amount and presses it when they say yes",
          "carry on with the parts that need no payment"))
    case .privateStore:
      return Blocked(
        "that place is Serein's own, a keychain or a password manager",
        routes: .init("ask for the same data through Serein's tools", "work from a copy inside your folder"))
    case .codeRunner:
      return Blocked(
        "Serein does not drive this app", routes: .init("run the same command with mac_run; same effect, sandboxed"))
    case .siteNever:
      return Blocked(
        "the person set this site to Never", routes: .init("another site, a search, or the service's API"),
        after: "Do not open this site.")
    case .siteAsk:
      return nil
    case .hostKey(let host):
      return Blocked(
        "the key for \(host) changed",
        routes: .init(
          "work with other hosts",
          "carry on with the rest and say in your report that the person checks the new key in Settings › Serein's computer"))
    }
  }

  /// A Serein update asked for during a task (R14).
  public static let update = Blocked("Serein updates when tasks end", routes: .init("carry on"))
}
