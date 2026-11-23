
import Foundation
import SereinCore

/// Grok Build over ACP: `grok … agent --no-leader stdio` on the grok.com sign-in. Grok reports no
/// mode, so its permission flag is held on argv. It reads files without asking Serein, so it runs
/// under the file guard.
struct GrokDriver: Driver {
  let cli = HarnessDriver.grok
  /// Held 600 s on one MCP call in the live tests.
  let cardWait: Duration = .seconds(600)
  var promptAddition: String {
    "Finish the task in this run without asking for confirmation. Edit files and run commands yourself. When you are done, list what you changed and what you checked, in a few lines."
  }

  static let dialect = ACPDialect(
    cli: .grok, model: .setModel, effortOption: "reasoning_effort", extensionUpdates: "_x.ai/session_notification")

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    let flags = HarnessPermissions.grokFlags(ACPGrant.of(request))
    // `--permission-mode` and `--always-approve` are global, so they lead. Grok's own sandbox is
    // off: macOS refuses a nested sandbox-exec inside the file guard.
    let arguments = flags + ["--sandbox", "off", "--disable-web-search", "agent", "--no-leader", "stdio"]
    var environment = ACPGrant.environment(request)
    // A key in the env flips the grok.com subscription to pay-as-you-go, own setup included:
    // only a key the person saved for Grok itself stays.
    if request.environment["XAI_API_KEY"] == nil { environment["XAI_API_KEY"] = nil }
    var contract = LaunchContract(
      request, arguments: arguments, environment: environment, expectedMode: .nothing(flagOnArgv: flags), network: network)
    contract.sandboxProfile = LaunchContract.fileGuard(request)
    return contract
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    try await ACPSession.open(process, contract: contract, request: request, dialect: Self.dialect)
  }

  func probe(executable: URL) async -> Readiness { await ACPProbe.readiness(executable) }
}
