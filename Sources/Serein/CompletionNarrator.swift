import Foundation
import SereinCore

@MainActor enum CompletionNarrator {
  #if DEBUG
  static var allowLiveForChecks = false
  static var responderForChecks: ((String) async throws -> String)?
  #endif
  static func explain(_ evidence: CompletionExplanation.Evidence, app: String, folder: String?, agent: AgentModel?) async -> String? {
    let prompt = CompletionExplanation.prompt(evidence)
    let raw: String
    do {
      #if DEBUG
      if let responderForChecks { raw = try await responderForChecks(prompt) }
      else {
        guard !RunMode.automated || allowLiveForChecks else { return nil }
        raw = try await request(prompt, agent: agent)
      }
      #else
      raw = try await request(prompt, agent: agent)
      #endif
    } catch { return nil }
    guard !Task.isCancelled, let result = CompletionExplanation.parse(raw, evidence: evidence) else { return nil }
    return CompletionExplanation.text(result, evidence: evidence, app: app, folder: folder)
  }
  private static func request(_ prompt: String, agent: AgentModel?) async throws -> String {
    guard let agent, let executable = agent.helperExecutable else { throw SereinError.invalid("No explanation model is available.") }
    return try await StructuredAgent().run(executable: executable, provider: agent.helperProvider,
      model: agent.helperModel, prompt: AgentPrivacy.redact(prompt))
  }
}
