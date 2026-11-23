#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// The guard in Engines: each thread's shell proxy asks the cards about a payment service and
/// answers "access denied" at once on a decline, an open card, or no cards at all; every wrapped
/// CLI carries the proxy environment, Claude and Codex hand the same port to their own shells;
/// a thread keeps its port across sends.
/// Names resolve from a fixed table; nothing leaves this Mac.
extension AssistantCoreChecks {
  static func engineShellGuard(_ check: Check) throws {
    let stripeIP = "198.137.150.221"
    let table = ["api.stripe.com": [stripeIP], "stripe.com": ["198.137.150.10"], "example.com": ["93.184.215.14"], "pass.test": ["127.0.0.1"]]
    let resolve: @Sendable (String) -> [String] = { table[$0] ?? [] }
    let notices = Recorded<String>()
    let book = MoneyBook(domains: ["stripe.com"], resolve: resolve)
    let shell = try ShellGuard(thread: "t1", book: book, resolve: resolve) { notices.add($0) }
    defer { shell.stop() }
    shell.begin(task: "task-1")
    func connect(_ name: String) throws -> EgressVerdict {
      try blocking { await shell.connect(EgressTarget(name: name, port: 443)) }
    }

    let twice = [try connect("api.stripe.com"), try connect("api.stripe.com")]
    try check(twice == [.refuse, .refuse],
      "With no cards attached, a shell call to Stripe is refused")
    try check(notices.all.count == 1 && notices.all[0].contains("api.stripe.com"), "The turn hears about it once per host per task")
    try check(try connect(stripeIP) == .refuse, "Stripe's address, learned when the book seeded, is refused too")
    try check(try connect("example.com") == .dial("93.184.215.14"), "example.com dials the address the guard resolved")
    try check(try connect("nowhere.invalid") == .unreachable, "A name with no address is unreachable, not refused")

    let declining = StubCards(.declined)
    shell.attach(declining)
    shell.saw(command: "curl https://api.stripe.com/v1/charges -u sk_live_51HxAbCdEfGhIjKlMnOpQrStUv:", task: "task-1")
    try check(try connect("api.stripe.com") == .refuse, "A declined card refuses the call")
    let ask = declining.asks.first
    try check(ask?.task == "task-1" && ask?.thread == "t1" && ask?.host == "api.stripe.com" && ask?.reason == .named,
      "The card names the task, thread, host and why")
    try check(ask?.command?.contains("sk_live_51HxAbCdEfGhIjKlMnOpQrStUv") == false, "The card's command line never carries a key")
    _ = try connect("example.com")
    try check(declining.asks.count == 1, "A host that is not a money service never asks")

    shell.attach(StubCards(.allowed))
    try check(try connect("api.stripe.com") == .dial(stripeIP), "An allowed card dials the resolved address")
    shell.attach(StubCards(.open))
    let started = Date()
    try check(try connect("api.stripe.com") == .refuse && Date().timeIntervalSince(started) < 5, "An open card refuses at once; the card stays")
    try check(shell.hello(.name("api.stripe.com"), opened: "example.com") == false, "A Stripe server name in an example.com tunnel is cut")

    try engineWiring(check)
  }

  private static func engineWiring(_ check: Check) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pay-wiring-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let records = RunRecords(root: folder.appendingPathComponent(".runs"))
    let engines = Engines(drivers: DriverRegistry.all, host: SereinProcessHost(records: records), records: records)
    defer { _ = try? blocking { await engines.shutdown() } }
    func request(_ cli: HarnessDriver, thread: String = "wiring") -> TurnRequest {
      TurnRequest(
        thread: ThreadKey(thread), cli: cli, executable: URL(fileURLWithPath: "/usr/bin/true"),
        access: .project(folder: folder, level: .full),
        prompt: TurnPrompt(stable: "s", volatile: "", message: "m", recovery: nil), model: nil, effort: nil, resume: nil,
        browser: nil, taskID: "wiring")
    }
    for driver in DriverRegistry.all {
      let name = driver.cli.rawValue
      guard let contract = try? blocking({ try await engines.contract(for: request(driver.cli)) }) else {
        try check(false, "\(name): Engines builds a contract")
        continue
      }
      let proxy = ShellNetwork.environment(port: contract.network.port)
      if driver.cli == .codex {
        try check(contract.routesOwnShells && proxy.keys.allSatisfy { key in contract.arguments.contains { $0.contains(key + "=") } },
          "\(name): its shells get the thread's proxy through the shell environment policy")
      } else if driver.routesOwnShells {
        try check(contract.routesOwnShells && contract.sandboxProfile == nil, "\(name): its own sandbox hands the shell the port")
      } else {
        try check(contract.guardApplied, "\(name): carries the proxy environment")
      }
      for allowsAll in [false, true] {
        try check(engines.promptAddition(for: driver.cli, allowsAll: allowsAll).hasSuffix(PayGuard.promptLine(allowsAll: allowsAll)),
          "\(name): the prompt says how a refused call reads at its level")
      }
    }
    let first = try blocking { try await engines.contract(for: request(.grok)) }
    let again = try blocking { try await engines.contract(for: request(.grok)) }
    let other = try blocking { try await engines.contract(for: request(.grok, thread: "other")) }
    try check(first.warmKey == again.warmKey, "Two sends on one thread keep the same warm key")
    try check(first.network != other.network, "Each thread has its own proxy port")
  }
}

final class Recorded<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [T] = []
  func add(_ item: T) { lock.withLock { items.append(item) } }
  var all: [T] { lock.withLock { items } }
}

/// Answers every ask the same way, at once.
final class StubCards: PayCards, @unchecked Sendable {
  private let answer: PayGuard.Answer
  private let lock = NSLock()
  private var seen: [PayGuard.Ask] = []
  var asks: [PayGuard.Ask] { lock.withLock { seen } }

  init(_ answer: PayGuard.Answer) { self.answer = answer }

  func ask(_ ask: PayGuard.Ask) async -> PayGuard.Answer {
    lock.withLock { seen.append(ask) }
    return answer
  }
}
#endif
