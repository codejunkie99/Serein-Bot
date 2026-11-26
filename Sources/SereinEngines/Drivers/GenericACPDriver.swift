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

extension ACPAgentSpec {
  /// A JSON list in Serein's data folder. Each object replaces the built-in driver of one ACP app
  /// and takes `ACPAgentSpec`'s field names, with `cardWaitSeconds` for `cardWait` and `model` as
  /// "setModel", "onArgv" or "configOption:<id>". Only `cli` and `arguments` are required.
  static let configFile = "acp-agents.json"

  private static let configFields: Set<String> = [
    "cli", "arguments", "cardWaitSeconds", "promptAddition", "model", "effortOption", "modelFlag",
    "modelRefusalEndsTurn", "stableElsewhere", "steerMethod", "supportsCancelResumeSteer",
  ]

  /// No file loads nothing and refuses nothing. A bad entry is refused with its reason and the
  /// other entries still load.
  static func load(from folder: URL) -> (specs: [ACPAgentSpec], refused: [String]) {
    let url = folder.appendingPathComponent(configFile)
    guard FileManager.default.fileExists(atPath: url.path) else { return ([], []) }
    guard let data = try? Data(contentsOf: url), let entries = (try? JSONDecoder().decode(JSON.self, from: data))?.array
    else { return ([], ["\(configFile) is not a readable JSON list, so no ACP agent was loaded from it"]) }
    var specs: [ACPAgentSpec] = []
    var refused: [String] = []
    for (index, entry) in entries.enumerated() {
      do {
        let spec = try ACPAgentSpec(config: entry)
        if specs.contains(where: { $0.cli == spec.cli }) {
          throw SereinError.invalid("\(spec.cli.rawValue) already has an entry above")
        }
        specs.append(spec)
      } catch {
        refused.append("\(configFile) entry \(index + 1) refused: \(error.localizedDescription)")
      }
    }
    return (specs, refused)
  }

  init(config entry: JSON) throws {
    func bad(_ reason: String) -> Error { SereinError.invalid(reason) }
    guard case .object(let fields) = entry else { throw bad("it is not a JSON object") }
    if let unknown = Set(fields.keys).subtracting(Self.configFields).sorted().first {
      throw bad("unknown field \"\(unknown)\"")
    }
    guard let name = fields["cli"]?.string else { throw bad("cli must name an app") }
    guard let cli = HarnessDriver(rawValue: name) else { throw bad("unknown cli \"\(name)\"") }
    guard cli.wire == .acp else { throw bad("\(cli.displayName) does not run over ACP") }
    guard let list = fields["arguments"]?.array, !list.isEmpty else { throw bad("arguments must be a list with at least one argument") }
    let arguments = list.compactMap(\.string)
    guard arguments.count == list.count, !arguments.contains("") else { throw bad("every argument must be a non-empty string") }

    func text(_ key: String) throws -> String? {
      guard let value = fields[key] else { return nil }
      guard let string = value.string, !string.isEmpty else { throw bad("\(key) must be a non-empty string") }
      return string
    }
    func flag(_ key: String) throws -> Bool? {
      guard let value = fields[key] else { return nil }
      guard let bool = value.bool else { throw bad("\(key) must be true or false") }
      return bool
    }

    var spec = ACPAgentSpec(cli: cli, arguments: arguments)
    if let value = fields["cardWaitSeconds"] {
      // The bound keeps the conversion to Duration from trapping on a huge number.
      guard let seconds = value.number, seconds > 0, seconds <= 86_400 else {
        throw bad("cardWaitSeconds must be a number of seconds above 0 and at most 86400")
      }
      spec.cardWait = .milliseconds(Int64((seconds * 1_000).rounded()))
    }
    if let model = try text("model") {
      switch model {
      case "setModel": spec.model = .setModel
      case "onArgv": spec.model = .onArgv
      case _ where model.hasPrefix("configOption:") && model.count > "configOption:".count:
        spec.model = .configOption(String(model.dropFirst("configOption:".count)))
      default: throw bad("model must be \"setModel\", \"onArgv\" or \"configOption:<id>\"")
      }
    }
    if let value = fields["promptAddition"] {
      guard let string = value.string else { throw bad("promptAddition must be a string") }
      spec.promptAddition = string
    }
    spec.effortOption = try text("effortOption")
    spec.modelFlag = try text("modelFlag")
    spec.steerMethod = try text("steerMethod")
    if let value = try flag("modelRefusalEndsTurn") { spec.modelRefusalEndsTurn = value }
    if let value = try flag("stableElsewhere") { spec.stableElsewhere = value }
    if let value = try flag("supportsCancelResumeSteer") { spec.supportsCancelResumeSteer = value }
    self = spec
  }
}
