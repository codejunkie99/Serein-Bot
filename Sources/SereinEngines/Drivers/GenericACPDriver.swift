import Foundation
import SereinCore

/// Data-driven specification for any ACP-compatible CLI agent so new ACP agents can plug in
/// without duplicating driver boilerplate.
struct ACPAgentSpec: Sendable, Equatable {
  var cli: HarnessDriver
  var arguments: [String]
  var cardWait: Duration
  var promptAddition: String
  var model: ACPDialect.ModelSetting
  var effortOption: String?
  var modelFlag: String?
  var modelRefusalEndsTurn: Bool
  var stableElsewhere: Bool
  var steerMethod: String?
  var supportsCancelResumeSteer: Bool

  init(
    cli: HarnessDriver,
    arguments: [String] = ["acp"],
    cardWait: Duration = .seconds(300),
    promptAddition: String = "",
    model: ACPDialect.ModelSetting = .setModel,
    effortOption: String? = nil,
    modelFlag: String? = nil,
    modelRefusalEndsTurn: Bool = false,
    stableElsewhere: Bool = false,
    steerMethod: String? = nil,
    supportsCancelResumeSteer: Bool = true
  ) {
    self.cli = cli
    self.arguments = arguments
    self.cardWait = cardWait
    self.promptAddition = promptAddition
    self.model = model
    self.effortOption = effortOption
    self.modelFlag = modelFlag
    self.modelRefusalEndsTurn = modelRefusalEndsTurn
    self.stableElsewhere = stableElsewhere
    self.steerMethod = steerMethod
    self.supportsCancelResumeSteer = supportsCancelResumeSteer
  }

  var dialect: ACPDialect {
    ACPDialect(
      cli: cli,
      model: model,
      effortOption: effortOption,
      modelRefusalEndsTurn: modelRefusalEndsTurn,
      stableElsewhere: stableElsewhere,
      steerMethod: steerMethod,
      supportsCancelResumeSteer: supportsCancelResumeSteer)
  }
}

/// Generic `Driver` implementation backed by `ACPAgentSpec` and `ACPSession`.
struct GenericACPDriver: Driver {
  let spec: ACPAgentSpec
  var cli: HarnessDriver { spec.cli }
  var cardWait: Duration { spec.cardWait }
  var promptAddition: String { spec.promptAddition }

  init(_ spec: ACPAgentSpec) { self.spec = spec }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    var args = spec.arguments
    if let flag = spec.modelFlag, let model = request.model, !model.isEmpty {
      args += [flag, model]
    }
    let expected: ExpectedMode = .nothing(flagOnArgv: spec.arguments.isEmpty ? ["acp"] : spec.arguments)
    var contract = LaunchContract(
      request, arguments: args, environment: ACPGrant.environment(request),
      expectedMode: expected, network: network)
    contract.sandboxProfile = LaunchContract.fileGuard(request)
    return contract
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    try await ACPSession.open(process, contract: contract, request: request, dialect: spec.dialect)
  }

  func probe(executable: URL) async -> Readiness { await ACPProbe.readiness(executable) }
}
