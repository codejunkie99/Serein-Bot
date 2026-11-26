import Foundation
import SereinCore

/// Gemini CLI over ACP (`gemini --acp`). Its model rides on argv. It reads files without asking
/// Serein, so it runs under the file guard.
struct GeminiDriver: Driver {
  let cli = HarnessDriver.gemini
  let cardWait: Duration = .seconds(118)
  var promptAddition: String {
    "Do not pause to ask for approval or confirmation between steps; continue until the task is complete. Read the files you need, make the edits, run the checks, then report."
  }

  /// Gemini names the MCP server behind a permission request; Serein's browser is allowed as such.
  static let dialect = ACPDialect(
    cli: .gemini, model: .onArgv,
    permissionKind: { asked, params in
      HarnessPermissionRequest.geminiKind(asked.kind, title: asked.title, server: ACPMessages.geminiServer(params))
    })

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    // Below Full it asks before commands, edits and web fetches, and Serein's grant answers.
    let mode = ACPGrant.full(request) ? ["--yolo"] : ["--approval-mode", "default"]
    var arguments = mode + ["--acp"]
    if let model = request.model, !model.isEmpty { arguments += ["-m", model] }
    var contract = LaunchContract(
      request, arguments: arguments, environment: ACPGrant.environment(request),
      expectedMode: .nothing(flagOnArgv: mode), network: network)
    contract.sandboxProfile = LaunchContract.fileGuard(request)
    return contract
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    try await ACPSession.open(process, contract: contract, request: request, dialect: Self.dialect)
  }

  func probe(executable: URL) async -> Readiness { await ACPProbe.readiness(executable) }
}
