import CryptoKit
import Foundation
import SereinCore

/// What a driver derives, purely, from a request: no I/O, so checks test it without a process.
struct LaunchContract: Sendable {
  let executable: URL
  /// Never carries the prompt.
  var arguments: [String]
  /// Kept apart because a warm process is reused across resumes.
  var resumeArguments: [String]
  /// Built with `CredentialEnv`, never inherited wholesale.
  var environment: [String: String]
  let access: Access
  let stablePrompt: String
  let ownSetup: Bool
  /// The browser helper's command line: its capability file names the task, so a warm process
  /// never outlives the capability it was started with.
  let browser: BrowserServer?
  var expectedMode: ExpectedMode
  let network: ShellNetwork.Plan
  /// Allow all's reach (LaunchContract+Level). ACP answers asks from a grant fixed at launch, so
  /// a level change needs a new process.
  let opensHome: Bool
  /// A `sandbox-exec` profile the CLI runs under (file rules for CLIs that read without asking).
  var sandboxProfile: String? = nil
  /// The CLI hands the proxy to its own shells (Claude's sandbox proxy ports, Codex's shell
  /// environment policy), so its own process keeps its environment. Any other driver gets the
  /// proxy environment from `guarded()`.
  var routesOwnShells = false

  init(
    _ request: TurnRequest, arguments: [String], resumeArguments: [String] = [], environment: [String: String],
    expectedMode: ExpectedMode, network: ShellNetwork.Plan
  ) {
    executable = request.executable
    self.arguments = arguments
    self.resumeArguments = resumeArguments
    self.environment = environment
    access = request.access
    stablePrompt = request.prompt.stable
    ownSetup = request.ownSetup
    browser = request.browser
    self.expectedMode = expectedMode
    self.network = network
    opensHome = request.opensHome
  }

  var argv: [String] { arguments + resumeArguments }

  /// The file guard for a CLI that reads files without asking Serein (Pi, Oh My Pi, Grok, Gemini,
  /// Cursor, OpenCode): the protected folders, other CLIs' sign-ins and Serein's own data, the
  /// library wherever it lives included, are closed at every level; secret files
  /// (`AgentFileGuard.secretRule`) are closed below Allow all (`secretsOpen`). Outside own setup,
  /// writes stay in the folder (`writableRoots`) and other tools' MCP lists stay closed.
  static func fileGuard(_ request: TurnRequest, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
    let own = ACPGrant.ownSetup(request)
    let folder = request.access.folder
    let profile = AgentFileGuard.ownSetupProfile(
      home: home, driver: request.cli, library: AgentAccess.defaultRoot, workspace: folder,
      extra: own ? [] : AgentFileGuard.foreignToolLists(home: home, driver: request.cli, folder: folder),
      writable: own ? nil : AgentFileGuard.writableRoots(home: home, driver: request.cli, folder: folder) + request.widened.map(\.path),
      openHome: request.opensHome)
    // The browser helper the CLI starts reads this task's capability and plugin list from the
    // closed run folder; every other task's stays closed.
    let mine = (request.browser?.arguments ?? [])
      .filter { $0.hasPrefix("/") && AgentFileGuard.leadsInto($0, roots: [AgentFileGuard.runRoot]) }
    let spellings = Set(mine + mine.map(AgentFileGuard.physicalPath)).sorted().map { "(literal " + jsonString($0) + ")" }
    let guarded = profile + (request.secretsOpen ? "" : AgentFileGuard.secretRule(home: home, driver: request.cli, folder: folder, library: AgentAccess.defaultRoot, fenced: !own))
    return spellings.isEmpty ? guarded : guarded + "(allow file-read* " + spellings.joined(separator: " ") + ")\n"
  }

  /// The shell network guard for a CLI Serein wraps: the proxy environment, which its shells
  /// inherit. No network fence (PAYGUARD-REVIEW M3).
  func guarded() -> LaunchContract {
    guard !routesOwnShells else { return self }
    var contract = self
    contract.environment.merge(ShellNetwork.environment(port: network.port)) { _, proxy in proxy }
    return contract
  }

  /// Whether a wrapped CLI's finished contract carries the proxy environment.
  var guardApplied: Bool {
    guard !routesOwnShells else { return false }
    return ShellNetwork.environment(port: network.port).allSatisfy { environment[$0.key] == $0.value }
  }

  /// Everything a running process never re-reads. A level change always gets a new process, so a
  /// warm one can never keep a looser mode.
  var warmKey: WarmKey {
    WarmKey([
      "executable": executable.path,
      "arguments": arguments.joined(separator: "\0"),
      "stablePrompt": stablePrompt,
      "environment": environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\0"),
      "folder": access.folder?.path ?? "",
      "level": access.level,
      "ownSetup": ownSetup ? "1" : "0",
      "opensHome": opensHome ? "1" : "0",
      "sandbox": sandboxProfile ?? "",
      "browser": browser.map { ([$0.command.path] + $0.arguments).joined(separator: "\0") } ?? "",
    ])
  }
}

/// A digest of a launch, with each field kept by name and hash only, so the close log can say
/// which field changed without leaking a prompt or a key.
struct WarmKey: Hashable, Sendable {
  let fields: [String: String]

  init(_ values: [String: String]) {
    fields = values.mapValues(Self.hash)
  }

  var digest: String { Self.hash(fields.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "\n")) }

  /// Names of the fields that differ, for the log line when a warm process is replaced.
  func changed(from other: WarmKey) -> [String] {
    Set(fields.keys).union(other.fields.keys).filter { fields[$0] != other.fields[$0] }.sorted()
  }

  private static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
