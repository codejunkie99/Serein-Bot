#if DEBUG
import Foundation
import SereinCore

/// The hidden model registry picks distinct providers first, skips what cannot answer, and reads
/// usage only from a provider's own count (ModelRegistry, UsageTally).
extension AssistantCoreChecks {
  static func modelRegistry(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let later = now.addingTimeInterval(3_600)
    func route(_ engine: String, _ model: String, _ cost: ModelRoute.CostClass = .yourPlan, caps: [ModelRoute.Capability] = [.tools]) -> ModelRoute {
      ModelRoute(provider: engine, model: model, costClass: cost, caps: caps, installed: true, reason: nil)
    }
    func row(_ route: ModelRoute, _ provider: String? = nil, _ remaining: ModelRegistry.Remaining = .unknown, tokens: Int = 0) -> ModelRegistry.Row {
      ModelRegistry.Row(route: route, provider: provider ?? route.provider, remaining: remaining, tokens5h: tokens)
    }
    let claude = route("claude", "opus"), codex = route("codex", "gpt-5"), gemini = route("gemini", "pro")
    let sonnet = route("claude", "sonnet"), haiku = route("claude", "haiku")
    let keyed = route("opencode", "serein-openrouter/openai/gpt-5", .yourKey)
    let local = route("opencode", "llama3.2", .free)
    let failed = ModelRegistry.build(routes: [claude, codex, gemini], provider: \.provider, tally: UsageTally(),
                                     limited: [:], failed: ["codex": later], now: now)
    let table: [(String, [ModelRegistry.Row], ModelRegistry.Need, Int, [ModelRoute])] = [
      ("A limited row is skipped", [row(claude, nil, .limited(until: later)), row(codex), row(gemini)], .init(), 2, [codex, gemini]),
      ("A row with nothing left is skipped", [row(claude, nil, .fraction(0)), row(codex, nil, .fraction(0.4))], .init(), 2, [codex]),
      ("A failed row is skipped", failed.rows, .init(), 3, [claude, gemini]),
      ("Free goes first and a route that bills each use goes last",
       [row(keyed, "openrouter"), row(claude), row(local, "ollama")], .init(), 3, [local, claude, keyed]),
      ("Two models on one provider: distinct providers are chosen first", [row(claude), row(sonnet), row(codex)], .init(), 2, [claude, codex]),
      ("A second model on a provider comes only after every provider has one", [row(claude), row(sonnet), row(codex)], .init(), 3, [claude, codex, sonnet]),
      ("At most two seats on one provider", [row(claude), row(sonnet), row(haiku)], .init(), 3, [claude, sonnet]),
      ("Among plans, the provider that spent fewer tokens lately goes first",
       [row(claude, nil, tokens: 900), row(codex, nil, tokens: 100)], .init(), 1, [codex]),
      ("Fewer rows than asked returns fewer, never a repeat", [row(claude), row(claude)], .init(), 3, [claude]),
      ("Width is capped at three delegated runs", [row(claude), row(codex), row(gemini), row(local, "ollama")], .init(), 5, [local, claude, codex]),
      ("A need for pictures skips text-and-tools routes", [row(claude), row(route("gemini", "pro", caps: [.tools, .vision]))],
       .init(tools: true, vision: true), 2, [route("gemini", "pro", caps: [.tools, .vision])]),
    ]
    for (label, rows, need, width, expected) in table {
      try check(ModelRegistry(rows: rows).pick(need: need, width: width) == expected, label)
    }

    var tally = UsageTally()
    tally.noteLeft("openrouter", 0.25, at: now)
    let built = ModelRegistry.build(routes: [claude, keyed], provider: { $0.provider == "opencode" ? "openrouter" : $0.provider },
                                    tally: tally, limited: [:], failed: [:], now: now)
    try check(built.rows.map(\.remaining) == [.unknown, .fraction(0.25)],
      "A Claude plan stays unknown while OpenRouter's own count fills its row only")
    try check(tally.remaining("openrouter", now: now.addingTimeInterval(UsageTally.countLife)) == .unknown,
      "A count older than its life goes back to unknown")
    tally.noteLimited("claude", UsageLimit(resetsAt: nil), at: now)
    try check(tally.remaining("claude", now: now) == .limited(until: now.addingTimeInterval(LimitFailover.unknownResetWait))
        && tally.remaining("claude", now: now.addingTimeInterval(LimitFailover.unknownResetWait)) == .unknown,
      "A refusal with no reset counts for an hour, then the plan is unknown again")
    let both = ModelRegistry.build(routes: [codex], provider: \.provider, tally: tally, limited: ["codex": later], failed: [:], now: now)
    try check(both.rows.first?.remaining == .limited(until: later), "The orchestrator's own limited list marks the row limited")
    tally.noteSpent("codex", 400, at: now)
    tally.noteSpent("codex", 0, at: now)
    tally.noteSpent("codex", 100, at: now.addingTimeInterval(60))
    try check(tally.tokens("codex", now: now.addingTimeInterval(60)) == 500
        && tally.tokens("codex", now: now.addingTimeInterval(UsageTally.spendLife + 30)) == 100
        && ModelRegistry.build(routes: [codex], provider: \.provider, tally: tally, limited: [:], failed: [:], now: now.addingTimeInterval(60))
          .rows.first?.tokens5h == 500,
      "Reported tokens count for five hours, and a zero report counts nothing")
    try check(tally.claimRead("openrouter", now: now) && !tally.claimRead("openrouter", now: now.addingTimeInterval(599))
        && tally.claimRead("openrouter", now: now.addingTimeInterval(600)),
      "The OpenRouter key is read at most once in ten minutes")

    func headers(_ values: [String: String]) -> (String) -> String? {
      { name in values.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }
    try check(UsageTally.headerLeft(headers(["X-RateLimit-Remaining-Requests": "30", "x-ratelimit-limit-requests": "120",
                                             "x-ratelimit-remaining-tokens": "90000", "x-ratelimit-limit-tokens": "100000"])) == 0.25,
      "OpenAI headers give the smallest share left")
    try check(UsageTally.headerLeft(headers(["anthropic-ratelimit-tokens-remaining": "800", "anthropic-ratelimit-tokens-limit": "1000"])) == 0.8,
      "Anthropic headers give the share left")
    try check(UsageTally.headerLeft(headers(["x-ratelimit-remaining-requests": "30"])) == nil
        && UsageTally.headerLeft(headers(["x-ratelimit-remaining": "5", "x-ratelimit-limit": "0"])) == nil
        && UsageTally.headerLeft(headers(["x-ratelimit-remaining": "-1", "x-ratelimit-limit": "10"])) == nil,
      "A remaining count with no limit, a zero limit or a negative count reads nothing")
    try check(UsageTally.openRouterKey(Data(#"{"data":{"limit":20,"limit_remaining":5,"usage":15}}"#.utf8)) == 0.25
        && UsageTally.openRouterKey(Data(#"{"data":{"limit":null,"limit_remaining":null,"usage":3}}"#.utf8)) == nil
        && UsageTally.openRouterKey(Data("<html>".utf8)) == nil,
      "OpenRouter's key gives limit_remaining over limit, and a key with no limit reads nothing")
  }
}
#endif
