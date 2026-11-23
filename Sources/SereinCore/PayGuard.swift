import Foundation

/// Which task-shell connections ask the person first. The network stays open (owner,
/// 2026-11-18); a payment or bank service, or an address Serein cannot name, raises a secure card.
/// Pure: the caller resolves names and answers the connection.
///
/// A courtesy card for cooperative tools, not a wall: the guard sees the name a client sends
/// through the proxy environment, so a tool that ignores it, or any relay (a name on another
/// service that forwards to a payment API), goes past it. The safety floor is elsewhere: card
/// values never reach the model, and secrets stay closed by the file guard below Allow all.
public enum PayGuard {
  /// Payment and money-moving services. Polar is two exact API hosts: Grok reaches mcp.polar.sh
  /// on every turn. Longer than `LocalExecution.paymentHosts`, which only the command words read.
  public static let hosts: [String] = LocalExecution.paymentHosts + [
    "braintree-api.com", "adyenpayments.com", "plaid.com", "wise.com", "transferwise.com", "gocardless.com",
    "mollie.com", "razorpay.com", "dwolla.com", "paddle.com", "lemonsqueezy.com", "coinbase.com", "klarna.com",
    "authorize.net", "revolut.com", "api.polar.sh", "sandbox-api.polar.sh",
  ]

  /// The money services, plus the addresses their names resolved to (learned at run time, never
  /// shipped). Addresses only name a bare-address connect: payment domains share CDN addresses
  /// with ordinary sites, so a name is judged by its name alone.
  public struct Book: Sendable, Equatable {
    public var domains: [String]
    /// Resolved address -> the money host it belongs to.
    public var addresses: [String: String]

    public init(domains: [String] = PayGuard.hosts, addresses: [String: String] = [:]) {
      self.domains = domains.map { $0.lowercased() }
      self.addresses = addresses
    }

    /// Label-suffix match: `api.stripe.com` is Stripe, `notstripe.com` is not.
    public func isMoney(_ host: String) -> Bool {
      let name = ConnectGate.normalizeHost(host)
      return domains.contains { name == $0 || name.hasSuffix("." + $0) }
    }
  }

  public enum Reason: Sendable, Hashable {
    /// The name is a money service.
    case named
    /// A bare address a money service's name resolved to.
    case sharesAddress(with: String)
    /// A public address with no name: Serein cannot tell which service it is.
    case byAddress
  }

  public enum Ruling: Sendable, Equatable {
    /// Dial exactly this address; the proxy never resolves twice.
    case pass(dial: String)
    case ask(host: String, dial: String, reason: Reason)
    case unresolved
  }

  /// One question for the person: may this task's shell reach `host`?
  public struct Ask: Sendable, Hashable {
    public let task: String
    public let thread: String
    public let host: String
    public let reason: Reason
    /// The thread's latest shell command, redacted and capped, for the card.
    public let command: String?

    public init(task: String, thread: String, host: String, reason: Reason, command: String?) {
      self.task = task
      self.thread = thread
      self.host = host
      self.reason = reason
      self.command = command
    }
  }

  /// `open`: the person has not answered; a card is up and the call is refused at once.
  public enum Answer: Sendable, Equatable { case allowed, declined, open }

  /// A loopback or private address passes; a public one with no name asks, naming the money
  /// service whose address it is when the book knows. A money name asks. Any other name passes
  /// at its first address.
  public static func judge(name: String, book: Book, resolve: (String) -> [String]) -> Ruling {
    let host = ConnectGate.normalizeHost(name)
    if ConnectGate.isRawIP(host) {
      if let money = book.addresses[host] { return .ask(host: host, dial: host, reason: .sharesAddress(with: money)) }
      return ConnectGate.isLocal(host) ? .pass(dial: host) : .ask(host: host, dial: host, reason: .byAddress)
    }
    guard let first = resolve(host).first else { return .unresolved }
    return book.isMoney(host) ? .ask(host: host, dial: first, reason: .named) : .pass(dial: first)
  }

  /// After the tunnel opens, from its first TLS record: a money server name under another
  /// tunnel name (fronting on a shared CDN) is refused. Anything not TLS, or with no name, passes.
  public static func helloAllowed(_ reading: TLSClientHello.Reading, opened: String, book: Book) -> Bool {
    guard case .name(let sni) = reading, book.isMoney(sni) else { return true }
    return sni == ConnectGate.normalizeHost(opened)
  }

  /// A fatal TLS `access_denied` alert, sent after the tunnel's success reply in answer to the
  /// ClientHello. curl, Python and Node print it as "access denied", through Codex's proxy too.
  public static let accessDenied = Data([0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x31])

  /// Appended to every driver's prompt addition, for the task's level: at Allow all payment
  /// hosts need no card, so the only "access denied" left is a mismatched TLS name.
  public static func promptLine(allowsAll: Bool) -> String {
    allowsAll ? """
      Shell HTTP and HTTPS go through Serein's local proxy; every host is reachable. If a call fails \
      with "access denied": Blocked: its TLS server name was a payment service other than the host it \
      connected to, which Serein refuses as spoofing. Route: connect to that payment host by its own name.
      """ : """
      Shell HTTP and HTTPS go through Serein's local proxy. A connection to a payment service, or to a \
      bare IP address, needs the person's yes in a Serein card. If a call fails with "access denied" \
      (or HTTP 403 from the proxy): Blocked: Serein asked the person on a card, or the person declined. \
      Routes: carry on with the rest of the task without retrying it; when the person answers, Serein \
      sends you a message to run it again. A TLS server name of a payment service sent inside another \
      host's connection is refused the same way: connect to that payment host by its own name.
      """
  }

  /// What the turn hears when a tunnel's TLS name was a payment service under another name.
  public static func spoofNotice(sni: String, opened: String) -> String {
    "Blocked: a shell connection to \(opened) sent the TLS name \(sni), a payment service; Serein refused it as spoofing. Route: connect to \(sni) by its own name."
  }

  /// The card: the host, why it asks, and the command that called it.
  public static func title(_ ask: Ask) -> String { "Let this task reach \(ask.host)?" }
  public static func lines(_ ask: Ask) -> [String] {
    let why: String
    switch ask.reason {
    case .named: why = "\(ask.host) is a payment service."
    case .sharesAddress(let money): why = "\(ask.host) shares an address with \(money), a payment service."
    case .byAddress: why = "\(ask.host) is an address with no name, so Serein cannot tell which service it is."
    }
    return [why] + (ask.command.map { ["Command: \($0)"] } ?? []) + ["Allow lets this chat's shell reach it from now on."]
  }

  /// The one turn sent when the person answers; the shell never waits for the card.
  public static func followUp(host: String, allowed: Bool) -> String {
    allowed
      ? "I allowed this task's shell to reach \(host). Run that call again, then carry on with the task."
      : "I declined this task's shell calls to \(host). Carry on without them, or take another route."
  }
}

/// The app's side of the guard: the secure card that asks the person.
public protocol PayCards: Sendable {
  /// Never waits for the person: the answer the thread already gave for the host, `.allowed` at
  /// Allow all, or `.open` after joining the open card or raising one. The person's answer later
  /// sends the thread one follow-up turn.
  func ask(_ ask: PayGuard.Ask) async -> PayGuard.Answer
}
