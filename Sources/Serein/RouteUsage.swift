import AppKit
import Combine
import SereinCore

/// What each model route used through Serein (UsageLedger), in `usage/routes.json` in the local
/// library. A turn counts when a run Serein launched ends (AgentHub.finish): one call, and the
/// tokens its CLI printed in its own output, else an estimate from Serein's prompt and reply.
/// No provider file, account page or network is read. Deleting the file starts the count over;
/// the period and warn levels are settings and stay.
@MainActor final class RouteUsage: ObservableObject {
  static let shared = RouteUsage()
  static let path = "usage/routes.json"
  static let resetKey = "serein.usage.reset"
  static let warnKey = "serein.usage.warnTokens"
  /// Settings › Usage offers these warn levels, in tokens per period; 0 is none.
  static let warnLevels = [0, 100_000, 500_000, 1_000_000, 5_000_000, 10_000_000, 50_000_000]
  @Published private(set) var ledger = UsageLedger()
  /// When every route's count starts over (Settings › Usage).
  @Published var reset: UsageReset {
    didSet { if !previewing { UserDefaults.standard.set(reset.rawValue, forKey: Self.resetKey) } }
  }
  /// Per route (`ModelRoute.id`): tokens in a period past which its picker cell turns amber.
  @Published private(set) var warnings: [String: Int]
  /// Why the last save failed, shown in Settings › Usage.
  @Published private(set) var status: String?
  private var library: Library?
  private var watch: AnyCancellable?
  /// A preview's count and settings stay in memory.
  private var previewing = false

  init() {
    reset = UsageReset(rawValue: UserDefaults.standard.string(forKey: Self.resetKey) ?? "") ?? .daily
    warnings = (UserDefaults.standard.dictionary(forKey: Self.warnKey) as? [String: Int]) ?? [:]
  }

  /// Loads the count. Previews, checks and stress runs count in memory only.
  func start(library: Library) {
    guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else { return }
    self.library = library
    migrateRelayTally(library)
    reload()
    // A file deleted while Serein was in the background reads as a fresh count on return.
    watch = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }
  }

  /// Re-reads the file; a missing or unreadable one is an empty count.
  func reload() {
    guard let library else { return }
    ledger = Self.load(library) ?? UsageLedger()
  }

  /// Counts one ended turn of a run Serein launched (`promptCharacters` is set at launch).
  func count(_ run: AgentRun) {
    guard let prompt = run.promptCharacters else { return }
    reload()
    let reported = run.record.tokens.flatMap { $0 > 0 ? $0 : nil }
    let lastAsk = run.transcript.lastIndex { $0.role == "user" } ?? -1
    let reply = run.transcript.indices.filter { $0 > lastAsk && run.transcript[$0].role == "assistant" }
      .reduce(0) { $0 + run.transcript[$1].text.count }
    ledger.add(
      route: UsageLedger.route(provider: run.initialSpec.provider.rawValue, model: run.initialSpec.model),
      tokens: reported ?? UsageLedger.estimate(characters: prompt + reply), reported: reported != nil)
    save()
  }

  func summary(_ route: String) -> UsageLedger.Summary { ledger.summary(route, reset: reset) }
  /// "~42 calls · ~180k tokens today (estimate)".
  func line(_ summary: UsageLedger.Summary) -> String { summary.line(period: reset.period()) }
  /// The route has a warn level and its period reached it.
  func crossed(_ route: String, _ summary: UsageLedger.Summary) -> Bool {
    guard let level = warnings[route], level > 0 else { return false }
    return summary.tokens >= level
  }
  func setWarning(_ route: String, tokens: Int) {
    warnings[route] = tokens > 0 ? tokens : nil
    UserDefaults.standard.set(warnings, forKey: Self.warnKey)
  }
  /// Each route with a warn level as a meter against it (UsageMeter), fullest first.
  var meters: [UsageMeter] { ledger.meters(warnings: warnings, reset: reset, name: Self.name) }
  /// Routes Settings lists: those counted in the kept days and those with a warn level.
  var shown: [String] { Array(Set(ledger.routes).union(warnings.keys)).sorted() }
  /// "Claude Code · Opus 4.5", from the route's harness and its model list.
  static func name(_ route: String) -> String {
    let parts = UsageLedger.split(route)
    let provider = Provider(rawValue: parts.provider)
    let model = parts.model.isEmpty
      ? "default" : HarnessRegistry.shared.models(provider).first { $0.id == parts.model }?.name ?? parts.model
    return provider.name + " · " + model
  }

  /// `--ui-affect-usage-meter`: a month on two routes, Claude near its warn level and Codex past
  /// it, only in memory.
  func previewMeters(now: Date = Date()) {
    previewing = true
    reset = .monthly(day: 1)
    let claude = UsageLedger.route(provider: Provider.claude.rawValue, model: "claude-opus-4-1")
    let codex = UsageLedger.route(provider: Provider.codex.rawValue, model: "gpt-5")
    var seeded = UsageLedger()
    let days = Calendar.autoupdatingCurrent.component(.day, from: now)
    for back in 0..<days {
      let day = now.addingTimeInterval(-Double(back) * 86_400)
      seeded.add(route: claude, calls: 6, tokens: 430_000 / days, reported: true, at: day)
      seeded.add(route: codex, calls: 4, tokens: 560_000 / days, reported: false, at: day)
    }
    ledger = seeded
    warnings = [claude: 500_000, codex: 500_000]
  }

  /// Deletes the file: every route starts again at zero.
  func clear() {
    ledger = UsageLedger()
    guard let library else { return }
    try? FileManager.default.removeItem(at: library.root.appendingPathComponent(Self.path))
  }

  private static func load(_ library: Library) -> UsageLedger? {
    let file = library.root.appendingPathComponent(path)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 2_000_000,
      let saved = library.load(UsageLedger.self, from: path), saved.isValid
    else { return nil }
    return saved
  }

  @discardableResult private func save() -> Bool {
    guard let library else { return false }
    do {
      let folder = library.root.appendingPathComponent("usage")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try library.save(ledger, to: Self.path)
      status = nil
      return true
    } catch {
      status = "Model usage could not be saved: \(error.localizedDescription)"
      return false
    }
  }

  /// Relay's daily token totals (`relay/tokens.json`, kept before routes were counted) join the
  /// ledger once, under no route, so Settings › Usage keeps their days; the old file goes.
  private func migrateRelayTally(_ library: Library) {
    struct Day: Decodable {
      var day: Date
      var tokens: Int
    }
    let old = library.root.appendingPathComponent("relay/tokens.json")
    guard FileManager.default.fileExists(atPath: old.path) else { return }
    var merged = Self.load(library) ?? UsageLedger()
    let edge = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -UsageLedger.keptDays, to: Date()) ?? .distantPast
    for day in library.load([Day].self, from: "relay/tokens.json") ?? [] where day.day >= edge && day.tokens > 0 {
      // Only this migration writes route "": a day that has one was migrated before.
      let key = LocalUsageLedger.dayKey(day.day)
      if merged.entries.contains(where: { $0.route == "" && $0.day == key }) { continue }
      merged.add(route: "", calls: 0, tokens: day.tokens, reported: true, at: day.day)
    }
    ledger = merged
    if save() { try? FileManager.default.removeItem(at: old) }
  }
}
