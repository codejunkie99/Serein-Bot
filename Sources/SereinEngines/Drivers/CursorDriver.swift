import Foundation
import SereinCore

/// Cursor's agent over ACP (`cursor-agent … acp`). Its flags go before `acp`. Its own sandbox is
/// off inside the file guard (macOS refuses a nested sandbox-exec), which closes what its sandbox used to.
struct CursorDriver: Driver {
  let cli = HarnessDriver.cursor
  let cardWait: Duration = .seconds(118)
  var promptAddition: String {
    "Instructions for this task: carry it out fully in this run. Do not stop after planning or after the first edit, and do not ask whether to continue. Run the project's build or tests after your changes and fix what fails."
  }

  /// Without the picker meta Cursor offers only its default model.
  static let dialect = ACPDialect(
    cli: .cursor, clientMeta: .object(["parameterizedModelPicker": .bool(true)]), model: .setModel,
    modelRefusalEndsTurn: true)

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    let full = HarnessPermissions.cursorFlags(ACPGrant.of(request))
    let sandbox = ["--sandbox", "disabled"]
    // `--approve-mcps` starts Serein's browser server from session/new without asking. Below
    // Full, Cursor asks before each tool and Serein's grant answers.
    let arguments = full + sandbox + ["--approve-mcps", "acp"]
    var contract = LaunchContract(
      request, arguments: arguments, environment: ACPGrant.environment(request),
      expectedMode: .nothing(flagOnArgv: full.isEmpty ? sandbox : full), network: network)
    // Its sign-in lives in the login keychain, which the guard closes: with that file shut
    // `cursor-agent status` says "Not logged in" (2026-11-18). Only the file reopens, to reads (the
    // last matching rule wins); the folder's other keychains stay closed, and nothing is written.
    let login = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
    let spellings = Set([login, AgentFileGuard.physicalPath(login)]).sorted().map { "(literal " + jsonString($0) + ")" }
    contract.sandboxProfile = LaunchContract.fileGuard(request)
    if !request.ownSetup {
      let closed = CursorPreflight.isolatedPaths(home: NSHomeDirectory(), environment: contract.environment, project: request.access.folder?.path)
      let rules = closed.map { "(subpath " + jsonString($0) + ")" }.joined(separator: " ")
      contract.sandboxProfile? += "(deny file-read* file-write* " + rules + ")\n"
    }
    contract.sandboxProfile? += "(allow file-read* " + spellings.joined(separator: " ") + ")\n"
    return contract
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    try await ACPSession.open(process, contract: contract, request: request, dialect: Self.dialect)
  }

  func probe(executable: URL) async -> Readiness { await ACPProbe.readiness(executable) }
}
