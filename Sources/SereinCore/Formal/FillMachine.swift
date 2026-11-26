import Foundation

/// The origin and payee rules of `FillGuard`, read through `PersonSaid`: two chats where the person
/// types messages that name a shop or none, saves the rule "ask me before you pay", and starts a
/// task in the second chat from the first; each tab goes to any of eight origins (the shop, its
/// www, a subdomain, another port, plain HTTP, and three lookalikes); and at every point either
/// chat fills its saved sign-in or card, or presses pay. Each step calls the shipped guard. The
/// oracle is the model's own labels for each message and origin, not the guard's parsing.
struct FillWorld: Encodable, Equatable {
  static let threads = ["a", "b"]
  static let eventCap = 4
  /// The person's messages, and whether each names the shop.
  static let messages: [(words: String, namesShop: Bool)] = [
    ("buy the blue mug on shop.example", true),
    ("pay for it at https://WWW.Shop.Example/cart", true),
    ("sign me in and book a table for two", false),
  ]
  /// Page origins: the shop's own (where a saved item fills), and the shop's site (where a pay may go).
  static let origins: [(origin: String, own: Bool, shopSite: Bool)] = [
    ("https://shop.example", true, true),
    ("https://www.shop.example", true, true),
    ("https://pay.shop.example", false, true),
    ("https://shop.example:8443", false, true),
    ("http://shop.example", false, false),
    ("https://shop.example.evil.io", false, false),
    ("https://shop-example.com", false, false),
    ("https://xn--shp-zna.example", false, false),
  ]
  static let saved = [
    FillGuard.Item(id: "s1", name: "sam", kind: .password, origins: ["https://shop.example"]),
    FillGuard.Item(id: "c1", name: "Visa", kind: .card, origins: ["https://shop.example"]),
  ]
  static let rule = MemoryRecord(
    id: "r1", kind: .rule, text: "Ask the person before you pay.", quote: "ask me before you pay", owner: "main",
    scope: .assistant("main"), provenance: MemoryProvenance(source: .person), review: .confirmed, personal: false)

  enum Event: Equatable { case said(Int, Int), rule, delegated }
  var events: [Event] = []
  var page = [0, 0]
  var last: Last?

  struct Last: Equatable {
    var thread: Int
    var action: String
    var origin: Int
    /// "fill", "pay", "ask" or "refused".
    var verdict: String
  }

  /// The chat's own words, rebuilt through the shipped store in the order they happened.
  func person(_ t: Int) -> FillGuard.PersonWords {
    let said = PersonSaid()
    var rules: [MemoryRecord] = []
    for event in events {
      switch event {
      case .said(let thread, let m): said.said(Self.messages[m].words, thread: Self.threads[thread])
      case .rule: rules = [Self.rule]
      case .delegated: said.inherit(Self.threads[1], from: Self.threads[0])
      }
    }
    return said.words(thread: Self.threads[t], rules: rules)
  }
  /// The oracle: the person named the shop in this chat, or in chat a before it started this one.
  func named(_ t: Int) -> Bool {
    var named = [false, false]
    for event in events {
      switch event {
      case .said(let thread, let m): named[thread] = named[thread] || Self.messages[m].namesShop
      case .delegated: named[1] = named[1] || named[0]
      case .rule: break
      }
    }
    return named[t]
  }
  var ruled: Bool { events.contains(.rule) }

  var key: String {
    let log = events.map { e -> String in
      switch e {
      case .said(let t, let m): return "s\(t)\(m)"
      case .rule: return "r"
      case .delegated: return "d"
      }
    }
    let lastKey = last.map { "\($0.thread)\($0.action)\($0.origin)\($0.verdict)" } ?? ""
    return [log.joined(separator: ","), page.map(String.init).joined(), lastKey].joined(separator: "|")
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(key)
  }

  static func steps(_ w: FillWorld) -> [(label: String, next: FillWorld)] {
    var out: [(label: String, next: FillWorld)] = []
    func add(_ label: String, _ change: (inout FillWorld) -> Void) {
      var n = w
      n.last = nil
      change(&n)
      out.append((label, n))
    }
    if w.events.count < eventCap {
      for t in threads.indices {
        for m in messages.indices where !w.events.contains(.said(t, m)) {
          add("\(threads[t]): the person types \"\(messages[m].words)\"") { $0.events.append(.said(t, m)) }
        }
      }
      if !w.events.contains(.rule) { add("the person saves \"ask me before you pay\"") { $0.events.append(.rule) } }
      if !w.events.contains(.delegated) { add("a starts a task in b") { $0.events.append(.delegated) } }
    }
    for t in threads.indices {
      for o in origins.indices where o != w.page[t] {
        add("\(threads[t]): the tab goes to \(origins[o].origin)") { $0.page[t] = o }
      }
      let origin = origins[w.page[t]].origin
      let person = w.person(t)
      for (action, kind) in [("fill sign-in", SecureCard.Kind.password), ("fill card", .card)] {
        let field = SecureCard.Field(
          kind: kind.rawValue, autocomplete: kind == .card ? "cc-number" : "current-password", frameOrigin: origin,
          topOrigin: origin, formOrigin: origin, trusted: origin.hasPrefix("https://"))
        let verdict: String
        if let target = FillGuard.target(field) {
          switch FillGuard.fill(target, saved: saved, person: person) {
          case .fill: verdict = "fill"
          case .ask: verdict = "ask"
          case .refused: verdict = "refused"
          }
        } else {
          verdict = "refused"
        }
        add("\(threads[t]): \(action) on \(origin)") { $0.last = Last(thread: t, action: action, origin: w.page[t], verdict: verdict) }
      }
      let paid: String
      switch FillGuard.pay(payee: origin, person: person) {
      case .pay: paid = "pay"
      case .ask: paid = "ask"
      case .refused: paid = "refused"
      }
      add("\(threads[t]): press pay on \(origin)") { $0.last = Last(thread: t, action: "pay", origin: w.page[t], verdict: paid) }
    }
    return out
  }

  static var machine: FormalMachine<FillWorld> {
    FormalMachine(
      name: "fills",
      bounds: "2 chats, \(eventCap) person events (3 messages each, 1 rule, 1 task start), \(origins.count) origins, fill sign-in, fill card and pay from either chat",
      start: FillWorld(), steps: FillWorld.steps,
      transitions: [
        ("a saved item fills only on its own origin", { _, _, after in
          guard let last = after.last, last.verdict == "fill" else { return true }
          return origins[last.origin].own
        }),
        ("a card fills and a pay presses only on a site the chat's own person named", { _, _, after in
          guard let last = after.last, last.verdict == "fill" && last.action == "fill card" || last.verdict == "pay"
          else { return true }
          return origins[last.origin].shopSite && after.named(last.thread)
        }),
        ("the rule \"ask me before you pay\" makes every card fill and pay ask (a plain HTTP card field is refused)", { _, _, after in
          guard let last = after.last, after.ruled, last.action != "fill sign-in" else { return true }
          return last.verdict == "ask" || (last.verdict == "refused" && !origins[last.origin].origin.hasPrefix("https://"))
        }),
        ("a saved sign-in on its own origin fills with no ask", { _, _, after in
          guard let last = after.last, last.action == "fill sign-in", origins[last.origin].own else { return true }
          return last.verdict == "fill"
        }),
        ("a named site's pay, and its own-origin card, go with no ask", { _, _, after in
          guard let last = after.last, !after.ruled, after.named(last.thread) else { return true }
          if last.action == "pay", origins[last.origin].shopSite { return last.verdict == "pay" }
          if last.action == "fill card", origins[last.origin].own { return last.verdict == "fill" }
          return true
        }),
      ],
      key: { $0.key })
  }
}
