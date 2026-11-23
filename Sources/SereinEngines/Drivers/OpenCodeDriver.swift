import Foundation
import SereinCore

/// OpenCode over ACP (`opencode acp --standalone`, 2.2.4). Its permissions and Serein's stable
/// prompt ride in `OPENCODE_CONFIG_CONTENT`: `OPENCODE_PERMISSION` has no effect on 2.x.
struct OpenCodeDriver: Driver {
  let cli = HarnessDriver.opencode
  /// Held 600 s on one MCP call in the live tests.
  let cardWait: Duration = .seconds(600)
  var promptAddition: String {
    "Work in the project folder with your edit, bash and search tools until the task is done. Do not hand back a plan or a list of suggested changes: make them. Keep replies short; the user reads the result, not the process."
  }

  static let dialect = ACPDialect(
    cli: .opencode, model: .configOption("model"), effortOption: "effort", stableElsewhere: true)

  /// A config folder Serein owns and empties before each launch: 2.x loads the person's plugins
  /// from theirs, and agents and plugins from this one. It sits in the library, which every
  /// guarded shell finds closed, and OpenCode only reads it.
  static var configFolder: URL { AgentAccess.defaultRoot.appendingPathComponent("engine-opencode-config", isDirectory: true) }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    let grant = ACPGrant.of(request)
    var environment = ACPGrant.environment(request)
    environment["OPENCODE_CONFIG_CONTENT"] = Self.config(
      grant: grant, stable: request.prompt.stable, providers: request.environment["OPENCODE_CONFIG_CONTENT"])
    // A repo's config, plugins and skills never load, own setup included.
    environment["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
    environment["OPENCODE_DISABLE_CLAUDE_CODE"] = "1"
    environment["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "1"
    environment["OPENCODE_PURE"] = "1"
    environment["OPENCODE_CONFIG_DIR"] = Self.configFolder.path
    // `acp` runs its own server child, never the person's background service, so it needs no
    // `--standalone` (2.2.4 refuses that flag here).
    var contract = LaunchContract(
      request, arguments: ["acp"], environment: environment,
      // The rules ride in the env above, on the `build` agent; its `mode` option must report it.
      expectedMode: .reports(["mode": "build"]), network: network)
    let config = [Self.configFolder.path, AgentFileGuard.physicalPath(Self.configFolder.path)]
    contract.sandboxProfile = LaunchContract.fileGuard(request)
      + "(allow file-read* " + Set(config).sorted().map { "(subpath " + jsonString($0) + ")" }.joined(separator: " ") + ")\n"
    return contract
  }

  func prepare(_ contract: LaunchContract, request: TurnRequest) throws {
    try? FileManager.default.removeItem(at: Self.configFolder)
    try FileManager.default.createDirectory(
      at: Self.configFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  /// Serein's rules and stable prompt. Full allows every tool, but the rules that keep OpenCode in
  /// the folder and off the web still say no, so it never asks. `providers`: the registry's
  /// provider connections (ProviderRun.openCodeConfig); only their `provider` block is kept.
  static func config(grant: HarnessGrant, stable: String, providers: String? = nil) -> String {
    var rules = HarnessPermissions.openCodeConfigPermission(grant)
    if grant.permission == .fullAccess {
      rules = rules.filter { $0.value == "deny" }.merging(["*": "allow"]) { mine, _ in mine }
    }
    var permission: [String: Any] = rules
    // OpenCode takes the last matching pattern; the keys go out sorted, so the example file wins.
    if grant.mayRead {
      permission["read"] = ["*": "allow", "*.env": "deny", "*.env.*": "deny", "*.env.example": "allow"]
    }
    var config: [String: Any] = [
      "$schema": "https://opencode.ai/config.json", "permission": permission, "share": "disabled",
      "autoupdate": false, "plugin": [String](), "instructions": [String](),
      "agent": ["build": ["prompt": stable, "permission": permission]],
    ]
    if let providers, let block = (try? JSONSerialization.jsonObject(with: Data(providers.utf8)) as? [String: Any])?["provider"] {
      config["provider"] = block
    }
    let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    try await ACPSession.open(process, contract: contract, request: request, dialect: Self.dialect)
  }

  func probe(executable: URL) async -> Readiness { await ACPProbe.readiness(executable) }
}
