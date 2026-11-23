import Foundation

/// Site-specific password rules for pages without a passwordrules attribute.
public struct PasswordQuirks: Sendable {
  private let rules: [String: String]

  public init(rules: [String: String] = [:]) { self.rules = rules }

  /// Parses `{ "domain": { "password-rules": "minlength: 8; ..." } }`.
  public init(json: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
      throw SereinError.invalid("Password rules file is not a JSON object")
    }
    var result: [String: String] = [:]
    for (domain, entry) in object {
      if let rule = (entry as? [String: Any])?["password-rules"] as? String, !rule.isEmpty {
        result[domain.lowercased()] = rule
      }
    }
    rules = result
  }

  public var count: Int { rules.count }

  /// The rule text for a host: the exact host, then each parent domain down to the registrable
  /// domain (`login.accounts.example.co.uk` tries `accounts.example.co.uk`, then `example.co.uk`).
  public func rule(forHost host: String) -> String? {
    var candidate = host.lowercased()
    while candidate.hasSuffix(".") { candidate.removeLast() }
    guard !candidate.isEmpty, !candidate.contains(":"),
      !candidate.allSatisfy({ $0.isNumber || $0 == "." })
    else { return nil }
    let registrable = CookieSites.site(for: candidate)
    while true {
      if let rule = rules[candidate] { return rule }
      if candidate == registrable { break }
      guard let dot = candidate.firstIndex(of: ".") else { break }
      candidate = String(candidate[candidate.index(after: dot)...])
      if candidate.isEmpty { break }
    }
    return rules[registrable]
  }

  /// Parsed rules for a host, or nil when there is no usable quirk.
  public func parsedRules(forHost host: String) -> PasswordRules? {
    guard let text = rule(forHost: host) else { return nil }
    let parsed = PasswordRules.parse(text)
    return parsed.isEmpty ? nil : parsed
  }

  /// The page's own rules win; the site quirk applies only when the page gave none.
  public func effectiveRules(page: PasswordRules, host: String) -> PasswordRules {
    page.isEmpty ? (parsedRules(forHost: host) ?? page) : page
  }
}
