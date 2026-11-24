import Foundation
import SereinCore

/// One CLI. Everything CLI-specific (argv, env, config files, the wire protocol, the mode
/// read-back) lives in its driver under Drivers/; the core never names a CLI.
protocol Driver: Sendable {
  var cli: HarnessDriver { get }
  /// The longest this CLI keeps one tool call open.
  var cardWait: Duration { get }
  var stopLadder: [StopStep] { get }
  /// This CLI's own lines from PROMPTS.md. The app puts them right after the shared core in
  /// `TurnPrompt.stable` of a task turn; pure answers (helpers) never carry them.
  var promptAddition: String { get }
  /// The CLI hands the thread's proxy (`network`) to its own shells; Engines gives every other
  /// CLI the proxy environment (`LaunchContract.guarded`).
  var routesOwnShells: Bool { get }

  /// Pure: no I/O. Throws `EngineRefusal` when the CLI cannot honour the access.
  /// `network` names the thread's proxy port.
  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract

  /// Writes the files `contract` names (a settings file, a system-prompt file) right before the
  /// spawn, so `contract` stays pure. Runs again for every new process of the thread.
  func prepare(_ contract: LaunchContract, request: TurnRequest) throws

  /// Handshakes over the started process and reads the mode back. Must not return before
  /// `ModeCheck.verify` passed: the session carries the proof, and the core sends nothing until
  /// it exists. Throw a `StopReason` (`.modeMismatch`, `.signIn`, ...) to refuse.
  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession

  func probe(executable: URL) async -> Readiness
}

extension Driver {
  var stopLadder: [StopStep] { StopLadder.standard }
  func prepare(_ contract: LaunchContract, request: TurnRequest) throws {}
  var promptAddition: String { "" }
  var routesOwnShells: Bool { false }
}

/// A CLI session after its mode verified. One per process; it may serve many turns while warm.
protocol EngineSession: AnyObject, Sendable {
  var mode: VerifiedMode { get }
  /// The CLI's events as the machine reads them; finishes when the process is done.
  var wire: AsyncStream<WireEvent> { get }
  /// Sends one turn. `prompt.volatile` rides in the message; `prompt.recovery` replaces it when
  /// the CLI refused `request.resume`.
  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws
  /// Mid-turn input. Never re-queued by the core when `.indeterminate`.
  func steer(_ text: String) async -> SteerOutcome
  /// Whether this wire takes words mid-turn (Claude stdin, Codex `turn/steer`, Pi steer). When
  /// false the core hands the words back instead of calling `steer`.
  var steers: Bool { get }
  /// Runs before the stop ladder closes input, so a CLI that can end its own tools does.
  func cancel() async
  /// Whether the process takes another turn after this one. When false the core ends it at the
  /// turn's end and the next turn starts a new one.
  var reusable: Bool { get }
  /// The session sends `prompt.registry` itself (ACP's embedded resource); otherwise Engines
  /// moves it into `volatile`.
  var takesRegistry: Bool { get }
}

extension EngineSession {
  var takesRegistry: Bool { false }
  var steers: Bool { true }
  func cancel() async {}
  var reusable: Bool { true }
}
