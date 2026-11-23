#if DEBUG
import Foundation
import SereinCore

/// OpenCode 2.x: one version switch picks the launch flags, model list and sign-in, and 1.x keeps
/// what it had. Fixtures are trimmed from a recorded 2.2.4 run; nothing here starts OpenCode.
extension AssistantCoreChecks {
  static func openCode2(_ check: Check) throws {
    let v2 = OpenCodeAPI(version: "2.2.4")
    try check(
      v2 == .v2 && OpenCodeAPI(version: "1.14.3") == .v1 && OpenCodeAPI(version: nil) == .v1
        && OpenCodeAPI(version: "2.0.0") == .v2,
      "OpenCode 2.x speaks the 2.x API; 1.x and an unprobed version keep the 1.x one")
    try check(
      OpenCodeAPI.v1.serveArguments == ["serve", "--pure", "--hostname=127.0.0.1", "--port=0"]
        && v2.serveArguments == ["serve", "--hostname=127.0.0.1", "--port=0"],
      "1.x serves with --pure as before; 2.x, which rejects it, serves without it")
    try check(
      OpenCodeAPI.v1.modelArguments == ["models", "--verbose", "--pure"] && v2.modelArguments == ["models", "--standalone"]
        && v2.accountArguments == ["auth", "list", "--format", "json", "--standalone"]
        && OpenCodeAPI.v1.accountArguments == ["auth", "list"]
        && OpenCodeAPI.v1.consoleArguments == ["console", "orgs"] && v2.consoleArguments == nil,
      "The probe lists 2.x models and accounts on a private server; 1.x, which has no --format, lists accounts as plain text")

    // `opencode models --standalone` on 2.2.4 prints one slug per line, after any log noise.
    let listed = "Starting server…\nopencode/hy4-flash-free\nopencode/deepseek-v4.1-flash-free\nclaude-agent/claude-opus-4-8\n\nnot a model\n"
    let models = v2.models(listed)
    try check(
      models.map(\.id) == ["opencode/hy4-flash-free", "opencode/deepseek-v4.1-flash-free", "claude-agent/claude-opus-4-8"],
      "2.x's plain model list is read line by line, and only provider/model lines count")
    try check(v2.models("Error: unknown option --verbose").isEmpty, "A 2.x error line is no model")

    try check(
      HarnessCommands.signIn(.opencode, version: "2.2.4").arguments == ["auth", "login"]
        && HarnessCommands.signIn(.opencode, version: "1.14.3").arguments == ["console", "login"]
        && HarnessCommands.signIn(.opencode).arguments == ["console", "login"],
      "2.x signs in with auth login, which replaced console login; 1.x keeps console login")
    try check(
      HarnessCommands.signsInInTerminal(.opencode, version: "2.2.4") && !HarnessCommands.signsInInTerminal(.opencode, version: "1.14.3"),
      "2.x's sign-in asks for a provider in its terminal, so the terminal is shown")
  }
}
#endif
