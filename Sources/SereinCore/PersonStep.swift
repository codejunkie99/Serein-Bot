import CryptoKit
import Foundation

/// A step only the person can take (a payment press, a check, a yes to one step), raised by the
/// model with `person_step`. The tool answers at once and the task goes on; the person's answer
/// comes back later as a steer or one follow-up turn (`ComposerFlow.deliver`). Every key is built
/// by code from the page or the call, never from words the model chose. Pure, so it is checked.
public enum PersonStep {
  public static let tool = "person_step"
  /// A card unanswered this long closes, and the task hears `expired` (R26).
  public static let life: TimeInterval = 86_400

  public enum Kind: Sendable, Equatable {
    case pay(tab: String, ref: String)
    /// The secure_card path, kept for the wire.
    case secret
    /// A CAPTCHA, a passkey, or a field only the person types.
    case check
    case confirm(tool: String, argsHash: String, path: String?)
    case hostKey
    case signIn(app: HarnessDriver)
  }

  public enum Key: Sendable, Hashable {
    case pay(PayKey)
    case field(host: String, field: String)
    case step(tool: String, argsHash: String, path: String?)
    case page(host: String)
    case app(HarnessDriver)
    case host(String)
    /// A step on the person's own machine that takes their password (sudo, an admin prompt).
    case root(machine: String, command: String)
  }

  /// One pay press the person is asked about: the card names it, and a yes presses it once (R2).
  public struct PayKey: Sendable, Hashable, Codable {
    public let host: String
    /// The payee as the page shows it. Code reads no payee apart from the site, so this is the host.
    public let merchant: String
    /// The pay button's own label.
    public let item: String
    /// Exact, as the page shows it.
    public let amount: String
    public init(host: String, merchant: String, item: String, amount: String) {
      self.host = host
      self.merchant = merchant
      self.item = item
      self.amount = amount
    }
  }

  public enum Reply: Sendable, Equatable {
    case asked
    case askedBefore(declined: Bool)
    /// A yes the person gave before covers it: confirm only (R24).
    case done
  }

  /// The tool's result: fixed text, no page text.
  public static func fields(_ reply: Reply) -> [String: String] {
    switch reply {
    case .asked: return ["result": "asked", "next": "Carry on with every other part. Serein sends you the answer."]
    case .askedBefore(false):
      return ["result": "asked_before", "next": "The person already has this card. Do not ask again. Carry on."]
    case .askedBefore(true): return ["result": "asked_before", "next": "The person said no. Take another route."]
    case .done: return ["result": "done", "next": "A yes the person gave before covers this. Carry on."]
    }
  }
  public static func wire(_ reply: Reply) -> String {
    let data = try? JSONSerialization.data(withJSONObject: fields(reply), options: [.sortedKeys])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  /// A confirm binds to the exact call: its tool and a hash of its arguments (R16).
  public static func argsHash(_ arguments: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The card's title and detail. Only code-read facts and the call's own tool name go in.
  public static func card(_ key: Key) -> (title: String, detail: String, button: String) {
    switch key {
    case .pay(let pay):
      return ("Pay \(pay.amount) on \(pay.host)", "Serein presses \(pay.item) when you say yes.", "Pay")
    case .step(let tool, _, let path?):
      return ("Let this task reach \(path)", "Serein runs \(tool) there when you say yes.", "Allow")
    case .step(let tool, _, nil):
      return ("Allow \(tool)", "The task asks before this step because it cannot be undone.", "Allow")
    case .page(let host):
      return ("Check on \(host)", "The page asks for a person. Do it in the tab, then press Done.", "Done")
    case .field(let host, _): return ("Fill a field on \(host)", "Type it in the tab, then press Done.", "Done")
    case .host(let host): return ("The key for \(host) changed", "", "OK")
    case .app(let app): return ("Sign in to \(app.rawValue)", "", "OK")
    case .root(let machine, let command):
      return (
        "Your password on \(machine)",
        "This step needs your password, which Serein never types: \(command.prefix(300)). Do it on \(machine) yourself, then press Done.",
        "Done")
    }
  }

  /// The follow-up the task gets when the person answers a card.
  public static func answered(_ key: Key, yes: Bool) -> String {
    switch (key, yes) {
    case (.pay(let pay), true):
      return "The person said yes to paying \(pay.amount) on \(pay.host), and Serein pressed \(pay.item). Read the tab again and carry on."
    case (.pay(let pay), false): return "The person said no to paying \(pay.amount) on \(pay.host). Take another route."
    case (.step(_, _, let path?), true): return "The person widened this task to \(path). Carry on there."
    case (.step(let tool, _, _), true): return "The person said yes to \(tool). Run it now, and carry on."
    case (.step(let tool, _, _), false): return "The person said no to \(tool). Take another route."
    case (.page(let host), true), (.field(let host, _), true):
      return "The person finished their step on \(host). Read the tab again and carry on."
    case (.page(let host), false), (.field(let host, _), false):
      return "The person did not do their step on \(host). Take another route."
    case (.host(let host), _): return "The person answered the card for \(host). Carry on."
    case (.app(let app), _): return "The person answered the card for \(app.rawValue). Carry on."
    case (.root(let machine, _), true):
      return "The person did the step that needs their password on \(machine). Look at the screen again and carry on."
    case (.root(let machine, _), false):
      return "The person did not do the step that needs their password on \(machine). Take another route."
    }
  }

  /// A pay step whose amount or button the page does not show: nothing is asked (R1).
  public static let unreadPay = "Blocked: Serein cannot read the amount or the button for this payment. Routes: read the tab again and call person_step with kind pay on the button that shows the amount; or carry on with the parts that need no payment."
  /// The person said yes to paying, but the press did not go (the page changed).
  public static func payMissed(_ pay: PayKey) -> String {
    "The person said yes to paying \(pay.amount) on \(pay.host), but the page changed before Serein pressed \(pay.item). Read the tab again, and call person_step with kind pay once more if the button is still there."
  }

  /// R26: a card nobody answered for a day.
  public static func expired(_ card: String) -> String {
    "The person did not answer \(card). Finish the other parts, or finish stuck with \(card) as the next action."
  }
}
