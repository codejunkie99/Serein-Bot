import Foundation
import OSLog
import SereinCore

/// One thread's shell proxy: the port its CLI's HTTP and HTTPS go through, and the rules that
/// ask the person about a payment service. Keyed by thread, so the port, and with it the warm
/// key, stays the same across sends. A call the person has not answered is refused at once and
/// the card stays; the answer sends the thread one follow-up turn. Logs host and verdict only.
final class ShellGuard: EgressPolicy, @unchecked Sendable {
  private static let log = Logger(subsystem: "app.serein", category: "pay-guard")

  let thread: String
  private(set) var port: UInt16 = 0
  private let book: MoneyBook
  private let resolve: @Sendable (String) -> [String]
  private let notice: @Sendable (String) -> Void
  private let lock = NSLock()
  private var proxy: PluginEgress?
  private var task = ""
  private var command: String?
  private var cards: (any PayCards)?
  private var noticed: Set<String> = []

  /// `notice` reaches the thread's running turn, for a refusal no card asked about.
  init(
    thread: String, book: MoneyBook = .shared, resolve: @escaping @Sendable (String) -> [String] = ConnectGate.systemResolve,
    notice: @escaping @Sendable (String) -> Void
  ) throws {
    self.thread = thread
    self.book = book
    self.resolve = resolve
    self.notice = notice
    let proxy = try PluginEgress(policy: self)
    self.proxy = proxy
    port = proxy.port
  }

  /// New connections are charged to this task: the latest send on the thread. The last task's
  /// command never shows on this one's card.
  func begin(task: String) {
    lock.withLock {
      if self.task != task { command = nil }
      self.task = task
    }
  }

  /// The thread's latest shell command, for the card, from the task the guard is charged to.
  func saw(command: String, task: String) {
    lock.withLock { if self.task == task { self.command = AgentPrivacy.redact(command, limit: 200) } }
  }

  func attach(_ cards: (any PayCards)?) { lock.withLock { self.cards = cards } }

  func stop() {
    let proxy = lock.withLock { () -> PluginEgress? in
      defer { self.proxy = nil }
      return self.proxy
    }
    proxy?.stop()
  }

  func connect(_ target: EgressTarget) async -> EgressVerdict {
    let name = ConnectGate.normalizeHost(target.name)
    let addresses = ConnectGate.isRawIP(name) ? [] : await Self.lookUp(name, resolve)
    let ruling = PayGuard.judge(name: name, book: await book.book()) { _ in addresses }
    switch ruling {
    case .unresolved:
      return .unreachable
    case .pass(let dial):
      return .dial(dial)
    case .ask(let host, let dial, let reason):
      let (task, command, cards) = lock.withLock { (self.task, self.command, self.cards) }
      guard let cards else {
        Self.log.info("Refused \(host, privacy: .public): no card to ask")
        tell(task, host, "Serein refused a shell connection to \(host): it cannot ask you about payment services yet.")
        return .refuse
      }
      let answer = await cards.ask(PayGuard.Ask(task: task, thread: thread, host: host, reason: reason, command: command))
      Self.log.info("\(host, privacy: .public): \(String(describing: answer), privacy: .public)")
      return answer == .allowed ? .dial(dial) : .refuse
    }
  }

  func hello(_ reading: TLSClientHello.Reading, opened: String) -> Bool {
    guard PayGuard.helloAllowed(reading, opened: opened, book: PayGuard.Book()) else {
      if case .name(let sni) = reading {
        let task = lock.withLock { self.task }
        tell(task, sni + "\0" + opened, PayGuard.spoofNotice(sni: sni, opened: opened))
      }
      return false
    }
    return true
  }

  /// Once per task and key, so a retry loop does not repeat it.
  private func tell(_ task: String, _ key: String, _ text: String) {
    if lock.withLock({ noticed.insert(task + "\0" + key).inserted }) { notice(text) }
  }

  /// Name lookups block their thread, so they run on GCD's, off Swift's cooperative pool.
  static func lookUp(_ name: String, _ resolve: @escaping @Sendable (String) -> [String]) async -> [String] {
    await withCheckedContinuation { done in
      DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: resolve(name)) }
    }
  }
}

/// The addresses money services use, so a call by bare address names the service it reaches.
/// Seeds each money name and `api.<name>` at first use and every 6 h; an address not seen for
/// 24 h is dropped. Loopback and private addresses are never learned. Names are never judged by
/// these addresses (PayGuard.Book).
actor MoneyBook {
  static let shared = MoneyBook()
  private let domains: [String]
  private let resolve: @Sendable (String) -> [String]
  private let now: @Sendable () -> Date
  private var seen: [String: (host: String, at: Date)] = [:]
  private var refreshed: Date?
  private var refreshing: Task<[(String, [String])], Never>?

  init(
    domains: [String] = PayGuard.hosts,
    resolve: @escaping @Sendable (String) -> [String] = ConnectGate.systemResolve,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.domains = domains
    self.resolve = resolve
    self.now = now
  }

  func book() async -> PayGuard.Book {
    if refreshed.map({ now().timeIntervalSince($0) > 6 * 3600 }) ?? true { await refresh() }
    let cutoff = now().addingTimeInterval(-24 * 3600)
    seen = seen.filter { $0.value.at > cutoff }
    return PayGuard.Book(domains: domains, addresses: seen.mapValues(\.host))
  }

  private func learn(host: String, addresses: [String]) {
    for address in addresses where !ConnectGate.isLocal(address) { seen[address] = (host, now()) }
  }

  private func refresh() async {
    if let refreshing { _ = await refreshing.value; return }
    let names = Set(domains.flatMap { [$0, "api." + $0] })
    let lookup = Task { [resolve] in
      await withTaskGroup(of: (String, [String]).self) { group in
        for name in names { group.addTask { (name, await ShellGuard.lookUp(name, resolve)) } }
        return await group.reduce(into: []) { $0.append($1) }
      }
    }
    refreshing = lookup
    for (name, addresses) in await lookup.value { learn(host: name, addresses: addresses) }
    refreshed = now()
    refreshing = nil
  }
}
