import Foundation
import SereinCore

/// The hidden model registry (SereinCore/ModelRegistry.swift) built from the model list's routes,
/// and the usage taps that feed its tally when a turn ends.
extension RelayOrchestrator {
  static let usageTallyFile = "relay/usage-tally.json"

  /// Every route the AI apps list, as the model list builds them, with what each provider's own
  /// signals said about its usage. A swarm picks its seats' models from it (`swarmRoutes`).
  func modelRegistry(now: Date = Date()) -> ModelRegistry {
    let routes = Provider.allCases.flatMap { provider in
      agent.routes(provider, models: HarnessRegistry.shared.models(provider).filter { !$0.isLegacy }.map(\.id))
    }
    return ModelRegistry.build(
      routes: routes, provider: { Self.usageProvider(Provider(rawValue: $0.provider), model: $0.model) },
      tally: usageTally, limited: limitedApps, failed: failedApps, now: now)
  }

  /// Who counts a route's usage: the provider connection its model belongs to, else the engine.
  static func usageProvider(_ engine: Provider, model: String) -> String {
    guard let driver = engine.driver, driver == .claude || driver == .opencode,
      let c = ProviderRun.connection(forModel: model, wire: driver == .claude ? .anthropic : .openai, in: ProviderStore.shared.enabled)
    else { return engine.rawValue }
    return c.id
  }

  /// After every turn: the share its provider said is left, the tokens its own report counted, the
  /// limit that refused it, and for an OpenRouter route one read of the key's own count, at most
  /// every `UsageTally.readEvery`. Never on a timer.
  func tallyUsage(_ run: AgentRun, now: Date = Date()) {
    let provider = Self.usageProvider(run.spec.provider, model: run.spec.model)
    if let share = run.usageLeft { usageTally.noteLeft(provider, share, at: now) }
    // Against the provider and against the model, so a swarm's seats on one provider part.
    if let tokens = run.record.tokens ?? run.reportedContext {
      usageTally.noteSpent(provider, tokens, at: now)
      usageTally.noteSpent(UsageTally.modelKey(provider, run.spec.model), tokens, at: now)
    }
    run.usageLeft = nil
    run.reportedContext = nil
    if let limit = run.usageLimit { usageTally.noteLimited(provider, limit, at: now) }
    guard provider == "openrouter", usageTally.claimRead(provider, now: now) else { return }
    Task { [weak self] in
      guard let share = await ProviderStore.shared.openRouterLeft() else { return }
      self?.usageTally.noteLeft(provider, share, at: Date())
    }
  }
}
