#if DEBUG
import Foundation
import SereinCore

/// Signing in to an AI app: OpenCode counts as signed in only with an account, a failed step
/// names the step that ran and its job's reason, and a sign-in that never exits finishes once
/// the app can answer.
extension AssistantCoreChecks {
  static func signInFlow(_ check: Check) throws {
    // A sign-in anywhere (Terminal, the app's own page, the chat) rewrites the app's sign-in
    // file; Serein watches it so the row updates on screen without reopening Settings.
    try check(
      ModelSources.signInFile(.opencode, environment: [:], home: "/Users/a") == "/Users/a/.local/share/opencode/auth.json"
        && ModelSources.signInFile(.opencode, environment: ["XDG_DATA_HOME": "/d"], home: "/Users/a") == "/d/opencode/auth.json"
        && ModelSources.signInFile(.grok, environment: [:], home: "/Users/a") == "/Users/a/.grok/auth.json"
        && ModelSources.signInFile(.grok, environment: ["GROK_HOME": "/g"], home: "/Users/a") == "/g/auth.json"
        && ModelSources.signInFile(.grok, environment: ["GROK_HOME": "relative"], home: "/Users/a") == "/Users/a/.grok/auth.json"
        && ModelSources.signInFile(.claude, environment: [:], home: "/Users/a") == nil,
      "OpenCode's and Grok's sign-in files are watched where each app keeps them, and a relative folder is ignored")

    let listed = """
      [{"id":"opencode-go","name":"OpenCode Go","connections":[{"type":"credential","label":"API key"}]},
       {"id":"openai","name":"OpenAI","connections":[{"type":"credential","label":"OAuth"}]},
       {"id":"zai","name":"Z.AI","connections":[]}]
      """
    try check(
      HarnessParse.openCodeAccounts(listed) == ["OpenCode Go", "OpenAI"] && HarnessParse.openCodeAccounts("[]") == [],
      "OpenCode's connected accounts are read by name from its account list, and free models alone are no account")
    try check(
      HarnessParse.openCodeAccounts("OpenCode Go   API key   stored") == nil && HarnessParse.openCodeAccounts("") == nil,
      "An account list OpenCode did not print as JSON says nothing, so Sign in stays offered")
    // `opencode auth list` on 1.19.5 (no --format there): stored credentials, then any keys found
    // in the environment, which a run may not have and so count for nothing.
    let plain = """
      \u{1B}[0m
      ┌  Credentials \u{1B}[90m~/.local/share/opencode/auth.json
      │
      ●  MiniMax Token Plan (minimax.io) \u{1B}[90mapi
      │
      ●  OpenAI \u{1B}[90moauth
      │
      └  2 credentials

      ┌  Environment
      │
      ●  MiniMax (minimax.io) \u{1B}[90mMINIMAX_API_KEY
      │
      └  1 environment variable
      """
    try check(
      HarnessParse.openCodeAccounts(plain) == ["MiniMax Token Plan (minimax.io)", "OpenAI"]
        && HarnessParse.openCodeAccounts("┌  Credentials ~/.local/share/opencode/auth.json\n│\n└  0 credentials") == [],
      "OpenCode 1.x's plain account list is read by its stored credentials only, and none listed is no account")
    // Serein's Sign in runs `console login` on 1.x, whose account `auth list` never shows:
    // `console orgs` lists it (1.19.5, signed in), or says "No accounts found" (signed out).
    let orgs = """
      \u{1B}[0m
        \u{1B}[92m●\u{1B}[0m \u{1B}[96m\u{1B}[1mDefault\u{1B}[0m  \u{1B}[90mme@example.com\u{1B}[0m  \u{1B}[90mhttps://opencode.ai/console\u{1B}[0m  \u{1B}[90mwrk_01\u{1B}[0m
          Personal  \u{1B}[90mme@example.com\u{1B}[0m  \u{1B}[90mhttps://opencode.ai/console\u{1B}[0m  \u{1B}[90morg_01\u{1B}[0m
      """
    try check(
      HarnessParse.openCodeConsoleSignedIn(orgs) && !HarnessParse.openCodeConsoleSignedIn("\u{1B}[0m\nNo accounts found\n")
        && !HarnessParse.openCodeConsoleSignedIn("") && !HarnessParse.openCodeConsoleSignedIn("opencode console orgs\n\nlist orgs"),
      "OpenCode 1.x's console sign-in, which Sign in runs, counts as an account; none listed, or help text, is no account")
    try check(
      HarnessParse.openCodeAccountLabel(credentials: [], console: true) == "OpenCode Go connected"
        && HarnessParse.openCodeAccountLabel(credentials: ["OpenAI"], console: true) == "2 accounts connected"
        && HarnessParse.openCodeAccountLabel(credentials: ["OpenAI"], console: false) == "OpenAI connected"
        && HarnessParse.openCodeAccountLabel(credentials: [], console: false) == nil,
      "OpenCode's label counts its console sign-in with its stored credentials, and nothing signed in leaves Sign in offered")

    let grokListed = HarnessParse.grokModels("""
      You are logged in with grok.com.

      Default model: magpie/codex/gpt-6.1-sol

      Available models:
        - grok-4.7
        - grok-4.6
        - magpie/auto/grok-4.7
        * magpie/codex/gpt-6.1-sol (default)
        - magpie/claude/claude-opus-5-5
      """)
    try check(
      grokListed.auth.signedIn == true && grokListed.models.map(\.id) == ["grok-4.7", "grok-4.6"]
        && grokListed.models.filter(\.isDefault).map(\.id) == ["grok-4.7"],
      "Grok lists only its own models, never a router's routes to Codex or Claude, and its first own model is the default")

    let cache = Data("""
      {"models":[{"slug":"gpt-b","display_name":"GPT B","priority":2,"visibility":"list",
                  "supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}],"default_reasoning_level":"low"},
                 {"slug":"hidden-one","display_name":"Hidden","priority":0,"visibility":"hide"},
                 {"slug":"gpt-a","display_name":"GPT A","priority":1,"visibility":"list"}]}
      """.utf8)
    let fromCache = HarnessParse.codexModels(CodexModels.cached(cache))
    try check(
      fromCache.map(\.id) == ["gpt-a", "gpt-b"] && fromCache.filter(\.isDefault).map(\.id) == ["gpt-a"]
        && fromCache[1].effortLevels == ["low", "max"],
      "Codex shows its real models from its own cache before its server starts: hidden ones out, its first model the default, each with its own efforts")
    let live = HarnessParse.codexModels(CodexModels.choices(["data": [
      ["model": "gpt-a", "displayName": "GPT A"], ["model": "gpt-b", "displayName": "GPT B", "isDefault": true],
    ]]))
    try check(
      live.filter(\.isDefault).map(\.id) == ["gpt-b"] && !live.contains { $0.id.isEmpty }
        && HarnessParse.codexModels([]).isEmpty,
      "Codex's live list marks the model it runs by default; an empty list stays empty, with no made-up row")
    let bundled = HarnessRegistry.claudeManifest?.models(cliVersion: nil) ?? []
    try check(
      bundled.count >= 10 && bundled.filter(\.isDefault).count == 1,
      "Serein's bundled Claude Code model list loads, with one default")
    let claudeList = [
      HarnessModel(id: "claude-opus-5", name: "Opus 5", blurb: "", isDefault: true),
      HarnessModel(id: "claude-sonnet-5", name: "Sonnet 5", blurb: ""),
    ]
    let ownDefault = { (own: String?) in HarnessRegistry.ownDefault(claudeList, own: own).filter(\.isDefault).map(\.id) }
    try check(
      ownDefault("sonnet") == ["claude-sonnet-5"] && ownDefault("claude-sonnet-5[1m]") == ["claude-sonnet-5"]
        && ownDefault("someone-else") == [] && ownDefault(nil) == ["claude-opus-5"],
      "Claude Code's own model setting is the default row; an alias is its newest listed model; one the list lacks names none")

    try check(
      SereinConnect.ran(.signingIn) == .signIn && SereinConnect.ran(.installing) == .install
        && SereinConnect.ran(.updating) == .update && SereinConnect.ran(.checking) == .check,
      "A failed step is the one that ran: a sign-in is never called an install, and a check that did not finish is the check")
    try check(
      SereinConnect.failed("Gemini CLI", step: .signIn, reason: "Exited with code 1.")
        == "Gemini CLI did not sign in. Exited with code 1."
        && SereinConnect.failed("Pi", step: .check) == "Serein could not check Pi on this Mac."
        && SereinConnect.failed("Codex", step: .install) == "Codex did not install.",
      "The failed line names the app, the step and the job's own reason")

    typealias A = HarnessPrimaryAction
    try check(
      A.signedInWhileRunning(before: .signIn, now: .ready) && A.signedInWhileRunning(before: .signIn, now: .update)
        && !A.signedInWhileRunning(before: .signIn, now: .signIn) && !A.signedInWhileRunning(before: .signIn, now: .checking),
      "A running sign-in finishes as soon as the app can answer, and not before")
    try check(
      !A.signedInWhileRunning(before: .ready, now: .ready),
      "A sign-in started while the app could already answer (another OpenCode account) runs to its own end")
    try check(
      A.signInRecheckEvery >= 2 && A.signInRecheckLimit <= 600 && A.signInRecheckLimit > A.signInRecheckEvery,
      "While a sign-in runs the app is checked every few seconds, for a bounded time")

    let grok = HarnessCapabilities.base(.grok)
    let refused = HarnessPolicy.verdict(driver: .grok, capabilities: grok, mode: "project", edits: false, permission: .supervised)
    let answers = HarnessPolicy.verdict(driver: .grok, capabilities: grok, mode: "answer", edits: false, permission: .supervised)
    try check(
      !refused.allowed && refused.reason != nil && answers.allowed,
      "Grok stays out of Project mode with a reason, and Answer, which the composer offers instead, takes it")
    let home = URL(fileURLWithPath: "/Users/someone")
    let profile = AgentFileGuard.ownSetupProfile(home: home, driver: .grok)
    try check(
      !profile.contains("\"/Users/someone/.grok\"") && profile.contains("\"/Users/someone/.gemini\"")
        && profile.contains("\"/Users/someone/Library/Keychains\""),
      "Grok's runs keep its own home, where its sign-in lives (auth.json), and no other app's or the keychains")
  }
}
#endif
