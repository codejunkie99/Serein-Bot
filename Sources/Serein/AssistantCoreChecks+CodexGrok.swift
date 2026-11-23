#if DEBUG
import Foundation
import SereinCore

/// What the Codex and Grok audits proved (2026-11-16): one model on both Codex paths, sub-agent
/// tools off, a retried error that does not fail the turn, the key name Codex reads, Grok's own
/// effort levels, and a Grok config that stops asking refused for helper requests.
extension AssistantCoreChecks {
  static func codexGrok(_ check: Check) throws {
    let routing = CodexRouting.routing(["config": ["model": "gpt-own", "model_provider": "local", "notify": ["x"]]])
    try check(
      CodexRouting.arguments(routing) == ["model=\"gpt-own\"", "model_provider=\"local\""]
        && CodexRouting.arguments(routing, picked: "gpt-picked") == ["model_provider=\"local\""],
      "An unpicked Codex chat runs the config's own model on exec as on the app server, and a picked model is not overridden")

    let off = CodexParams.offConfigs()
    let server = CodexParams.serverArguments()
    try check(
      off.contains("agents.enabled=false") && off.contains("features.multi_agent=false")
        && off.count == CodexParams.disabledFeatures.count + 1
        && CodexParams.offConfigs(["apps"]) == ["features.apps=false", "agents.enabled=false"]
        && server.contains("agents.enabled=false") && server.contains("features.multi_agent=false"),
      "Codex runs and its app server switch sub-agent tools off with agents.enabled, and keep the feature flags")

    let retry: [String: Any] = ["type": "error", "message": "Reconnecting... 1/5", "will_retry": true]
    let plain: [String: Any] = ["type": "error", "message": "stream closed"]
    let failed: [String: Any] = ["type": "turn.failed", "error": ["message": "usage limit reached"]]
    let completed: [String: Any] = ["type": "turn.completed"]
    func standing(_ events: [[String: Any]]) -> String? {
      events.reduce(nil) { ExecErrors.standing($0, after: $1) }
    }
    try check(
      standing([retry]) == nil && standing([plain, ["type": "item.completed"], completed]) == nil
        && standing([plain]) == "stream closed" && standing([completed, plain]) == "stream closed"
        && standing([plain, retry]) == "stream closed",
      "A Codex exec error it retries, or one a completed turn follows, does not fail the turn; one left standing does")
    try check(
      standing([failed]) == "usage limit reached"
        && ExecErrors.message(["type": "error", "error": ["message": "inner"], "message": "outer"]) == "inner"
        && ExecErrors.message(["type": "turn.failed"]).contains("turn.failed"),
      "A failed Codex turn shows its error's own message, not the raw event")

    try check(
      HarnessEnvironment.keyName(.codex) == "CODEX_API_KEY" && HarnessEnvironment.keyName(.claude) == "ANTHROPIC_API_KEY"
        && AgentFileGuard.environment(["CODEX_API_KEY": "k", "OPENAI_API_KEY": "old"], driver: .codex, ownKey: "CODEX_API_KEY")["CODEX_API_KEY"] == "k"
        && AgentFileGuard.environment(["OPENAI_API_KEY": "old"], driver: .codex, ownKey: "OPENAI_API_KEY")["OPENAI_API_KEY"] == "old",
      "A Codex key saved with no name goes as CODEX_API_KEY, the one Codex reads; a name saved earlier still reaches it")

    // xAI refuses every turn from Grok below 1.0.13 ("API error (status 426 Upgrade Required):
    // Your Grok CLI version (1.0.3) is outdated", seen 2026-11-15), so Serein offers Update first.
    let grokVersion = HarnessParse.version("grok 1.0.3 (1a29d5bc12d4) [stable]")
    try check(
      grokVersion == "1.0.3"
        && HarnessVersionGate.refusal(driver: .grok, version: grokVersion, mode: "answer")?.contains("1.0.13 or later") == true
        && HarnessVersionGate.refusal(driver: .grok, version: "1.0.13", mode: "answer") == nil
        && HarnessVersionGate.refusal(driver: .grok, version: "1.0.77", mode: "research") == nil
        && HarnessVersionGate.refusal(driver: .grok, version: nil, mode: "answer") == nil,
      "A Grok below 1.0.13, which xAI refuses, is offered Update before a message goes; 1.0.13 and later send")

    let listed = HarnessParse.grokModels("""
      You are logged in with grok.com.

      Available models:
        - grok-4.7
        - grok-4.5
        - grok-4.7@500k
        - grok-plain
        - magpie/grok/grok-4.7@500k
      """).models
    try check(
      listed.map(\.id) == ["grok-4.7", "grok-4.5", "grok-4.7@500k", "grok-plain"] && listed.allSatisfy { $0.effortLevels.isEmpty },
      "A Grok model id with @ is listed, and no Grok model has effort levels Grok did not report")

    let effort: (String, Bool) -> [String: Any] = { ["id": $0, "value": $0, "label": $0, "default": $1] }
    let available: [[String: Any]] = [
      ["modelId": "grok-4.7", "name": "Grok 4.7", "_meta": ["supportsReasoningEffort": true, "reasoningEffort": "medium",
        "reasoningEfforts": [effort("xhigh", false), effort("high", true), effort("medium", false), effort("low", false)]] as [String: Any]],
      ["modelId": "grok-4.5", "name": "Grok 4.5", "_meta": ["supportsReasoningEffort": true, "reasoningEffort": "high",
        "reasoningEfforts": [effort("high", false), effort("medium", false), effort("low", false)]] as [String: Any]],
      ["modelId": "grok-4.7@500k", "name": "Grok 4.7 · 500k", "_meta": ["supportsReasoningEffort": false,
        "reasoningEfforts": [effort("high", true)]] as [String: Any]],
    ]
    let state: [String: Any] = ["currentModelId": "grok-4.7", "availableModels": available]
    let filled: [HarnessModel] = HarnessParse.grokEfforts(listed, reply: ["_meta": ["modelState": state]])
    let levels: [[String]] = filled.map(\.effortLevels)
    let defaults: [String?] = filled.map { $0.option("effort")?.defaultValue }
    let names: [String] = filled.map(\.name)
    try check(
      levels == [["low", "medium", "high", "xhigh"], ["low", "medium", "high"], [], []]
        && defaults == ["high", "high", nil, nil]
        && names == ["Grok 4.7", "Grok 4.5", "Grok 4.7 · 500k", listed[3].name]
        && HarnessParse.grokEfforts(listed, reply: ["models": state]) == filled
        && HarnessParse.grokEfforts(listed, reply: "not a reply") == listed,
      "Each Grok model gets the name and effort levels Grok reports for it; one with none, or one Grok does not name, gets no effort control")
    try check(
      HarnessOption.effortShown("high", levels: []) == nil && HarnessOption.effortShown("xhigh", levels: ["low", "xhigh"]) == "X-High"
        && HarnessParse.codexModels([ModelChoice(model: "plain", name: "Plain", tier: .balanced, blurb: "")])
          .first?.effortLevels == [],
      "A model that lists no effort levels shows no effort beside its name, on any AI app")

    let refused = [
      "[ui]\npermission_mode = \"always-approve\"\n", "[ui]\n  permission_mode='auto' # mine\n",
      "ui.permission_mode = \"always-approve\"\n", "[permission]\nrules = []\n", "[[permission.rules]]\naction = \"allow\"\n",
      "yolo = true\n", "approval_mode = \"never\"\n", "[mcp_servers.x]\ncommand = \"y\"\n",
    ]
    let accepted = [
      "[ui]\npermission_mode = \"ask\"\ntheme = \"dark\"\n", "yolo = false\n", "approval_mode = \"default\"\n",
      "default_reasoning_effort = \"xhigh\"\n", "",
    ]
    try check(
      refused.allSatisfy { GrokPreflight.problem(config: $0) != nil }
        && accepted.allSatisfy { GrokPreflight.problem(config: $0) == nil } && GrokPreflight.problem(config: nil) == nil,
      "Grok gets no helper requests while its config turns asking off (always-approve, a permission table, yolo, approval_mode)")
  }
}
#endif
