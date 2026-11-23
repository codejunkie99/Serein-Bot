#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  /// An AI app reads Ready only on its own positive answer, from a probe run that finished.
  static func probeTruth(_ check: Check) throws {
    let grokSignedOut = HarnessParse.grokModels("""
      You are not authenticated.

      Default model: grok-4.6

      Available models:
        * grok-4.6 (default)
        - grok-4.5
      """)
    let grokKey = HarnessParse.grokModels("You are using XAI_API_KEY.\n\nDefault model: grok-4.6\n").auth
    let codexOdd = HarnessParse.confirmed(
      HarnessParse.codexAuth("Unexpected output"), code: 0, timedOut: false, command: "codex login status")
    let signedIn = HarnessParse.Auth(signedIn: true)
    let late = HarnessParse.confirmed(signedIn, code: -1, timedOut: true, command: "codex login status")
    let failed = HarnessParse.confirmed(signedIn, code: 2, timedOut: false, command: "claude auth status")
    let out = HarnessParse.confirmed(HarnessParse.Auth(signedIn: false), code: 1, timedOut: false, command: "claude auth status")
    let geminiError = HarnessParse.geminiSession(["code": -32603, "message": "Internal error"] as [String: Any]).auth
    var row = HarnessSnapshot(instance: HarnessInstance(driver: .gemini))
    row.enabled = true
    row.installed = true
    row.acpArguments = ["--acp"]
    row.checkedAt = Date()
    row.signInProblem = "`gemini` did not answer in time."
    let summary = HarnessSnapshot.summarize(row, name: "Gemini CLI")
    let results: [(Bool, String)] = [
      (grokSignedOut.auth.signedIn == false, "Grok's \"You are not authenticated\" reads as signed out, not Ready"),
      (grokKey.signedIn == true && grokKey.account == "xAI API key", "Grok on its own XAI_API_KEY reads as signed in with that key"),
      (codexOdd.signedIn != true && codexOdd.problem != nil, "Codex output that never says it is logged in is no sign-in, even with exit 0, and says why"),
      (late.signedIn == nil && late.problem?.contains("did not answer") == true, "A sign-in read from a probe that timed out is no answer, and says so"),
      (failed.signedIn == nil && failed.problem?.contains("exited with 2") == true, "A sign-in read from a probe that failed is no answer, and says so"),
      (out.signedIn == false, "A probe's own signed-out answer stands whatever its exit code"),
      (geminiError.signedIn == nil && geminiError.problem?.contains("Internal error") == true, "A Gemini CLI session error that is not about sign-in is named, not read as Ready"),
      (summary.0 == .error && summary.1 == row.signInProblem && HarnessPrimaryAction.of(row) == .signIn,
        "An app whose probe could not confirm a sign-in shows why and offers Sign in, never Ready"),
    ]
    for (ok, label) in results { try check(ok, label) }
  }
}
#endif
