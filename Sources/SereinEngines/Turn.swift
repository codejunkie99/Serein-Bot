import Foundation
import SereinCore

public struct ThreadKey: Hashable, Sendable {
  public var id: String
  public init(_ id: String) { self.id = id }
}

/// Everything a turn needs, in Serein's terms. No argv, env or wire names: drivers derive those.
public struct TurnRequest: Sendable {
  public var thread: ThreadKey
  /// Which CLI, and the exact binary AgentLaunchIdentity validated.
  public var cli: HarnessDriver
  public var executable: URL
  public var access: Access
  public var prompt: TurnPrompt
  public var model: String?
  public var effort: String?
  /// The CLI's own session id from the last turn on this thread; nil starts a new session.
  public var resume: String?
  /// Resume into a copy of `resume`: another app still holds that session (LinkedSessions).
  public var forkSession = false
  /// Serein's browser MCP helper, nil when this access has no browser.
  public var browser: BrowserServer?
  /// Copies the person attached for this turn (read-only roots).
  public var attachments: [URL]
  public var images: [URL]
  /// The task that owns the browser capability; a warm session hands it over.
  public var taskID: String
  /// The session-scope string this turn runs under (`privacy-v1|...|own|relay`).
  public var sessionScope: String?
  /// The scope `resume` was recorded under. A remote id resumes only in the scope that made it;
  /// otherwise the turn starts a new session.
  public var resumeScope: String?
  /// Tool calls allowed in this turn before it is cut. Ignored for a task, which the loop guard
  /// watches instead.
  public var stepBudget: Int?
  /// The reply must be JSON matching this schema (pure-answer callers). The driver asks the CLI
  /// for it in its own way.
  public var schema: String?
  /// The person chose to run this CLI with their own config, MCP servers and env (`Access.ownSetup`).
  public var ownSetup: Bool {
    if case .ownSetup = access { return true }
    return false
  }
  /// What the person gave this CLI, added to its environment (`CredentialEnv.child`): their extra
  /// variables and Keychain key, `PATH` from their login shell, and under own setup the login
  /// shell's environment. The app fills it (HarnessRegistry.prepare); part of the warm key.
  public var environment: [String: String] = [:]
  /// The model is a provider connection's (ProviderStore.run): Claude Code's child keeps no
  /// inherited or person's routing variable (ProviderRun.routesClaude), only the connection's.
  public var providerTurn = false
  public var directHTTP: DirectHTTPRoute?
  /// The task stands at Allow all (Proactive): a wrapped CLI's shell may read secret files
  /// (owner, 2026-11-18). It changes the sandbox profile, which is in the warm key, so a level
  /// change relaunches the CLI.
  public var secretsOpen = false
  /// Folders the person widened this task to (PathGrants.roots, R22): writable past the folder,
  /// never past the closed paths. In the sandbox profile, so a widening relaunches the CLI.
  public var widened: [URL] = []
  /// Re-checks the executable's identity, its grant and consent right before each spawn; a
  /// refusal (`.needsRepair` for a signed-out CLI) starts nothing.
  public var revalidate: (@Sendable () async -> EngineRefusal?)?
  /// The chat's level. Allow all opens home and the network natively (LaunchContract+Level).
  public var level: ApprovalLevel

  public init(
    thread: ThreadKey, cli: HarnessDriver, executable: URL, access: Access, prompt: TurnPrompt, model: String?,
    effort: String?, resume: String?, browser: BrowserServer?, attachments: [URL] = [], images: [URL] = [],
    taskID: String, sessionScope: String? = nil, resumeScope: String? = nil, stepBudget: Int? = nil,
    schema: String? = nil, revalidate: (@Sendable () async -> EngineRefusal?)? = nil,
    level: ApprovalLevel = .everyStep
  ) {
    self.thread = thread
    self.cli = cli
    self.executable = executable
    self.access = access
    self.prompt = prompt
    self.model = model
    self.effort = effort
    self.resume = resume
    self.browser = browser
    self.attachments = attachments
    self.images = images
    self.taskID = taskID
    self.sessionScope = sessionScope
    self.resumeScope = resumeScope
    self.stepBudget = stepBudget
    self.schema = schema
    self.revalidate = revalidate
    self.level = level
  }

  /// `resume` when its scope matches this turn's, else nil.
  public var scopedResume: String? { resumeScope == sessionScope ? resume : nil }
}

/// What the turn may touch. Each case carries exactly the data it needs, so "edits outside a
/// project" or "Full in Library" cannot be written down.
public enum Access: Hashable, Sendable {
  /// No tools (Answer).
  case answer
  /// Serein's browser only (Research, Page).
  case web
  /// Read-only over RecallSandbox copies (Library).
  case library(URL)
  /// The person's own CLI setup, no edits, no browser.
  case ownSetup(folder: URL)
  /// A chat turn in a project folder at the level the person picked.
  case project(folder: URL, level: ProjectLevel)
  /// A delegated task. It has no level: a task always runs Full, so no caller can pass a weaker
  /// or looser one.
  case task(folder: URL)

  var folder: URL? {
    switch self {
    case .answer, .web: return nil
    case .library(let folder), .ownSetup(let folder), .project(let folder, _), .task(let folder): return folder
    }
  }

  /// Full and a task never ask the person, so a refusal there is not theirs to see.
  var asks: Bool {
    switch self {
    case .task, .project(_, .full): return false
    case .answer, .web, .library, .ownSetup, .project: return true
    }
  }

  /// The no-ask level the CLI runs at; part of the warm key.
  var level: String {
    switch self {
    case .answer: return "answer"
    case .web: return "web"
    case .library: return "library"
    case .ownSetup: return "ownSetup"
    case .project(_, let level): return level.rawValue
    case .task: return ProjectLevel.full.rawValue
    }
  }
}

/// A chat turn's level in a project. `.full` never asks; the fence still holds.
public enum ProjectLevel: String, Hashable, Sendable, CaseIterable {
  case review  // read only
  case edits  // edits in the folder, no shell
  case commands  // edits + shell, asks before risky commands
  case full  // edits + shell, never asks
}

/// The prompt split from PROMPTS.md. `stable` is byte-identical across turns of a thread and is
/// part of the warm key. `volatile` changes per turn and rides in the message, so a warm process
/// keeps its cached prefix.
public struct TurnPrompt: Hashable, Sendable {
  public var stable: String
  public var volatile: String
  public var message: String
  /// The message with the conversation pasted, sent once only if the CLI refused `resume` before
  /// it accepted the prompt.
  public var recovery: String?
  /// A session command the CLI advertised (ACP `/compact`), sent instead of `message` on a resumed
  /// session only.
  public var command: String? = nil
  /// The chat registry's slice for a cold session (ChatRegistry.slice). ACP takes it as an
  /// embedded resource; every other engine reads it ahead of `volatile` (`contextInVolatile`).
  public var registry: String? = nil
  /// A seat's hand-off packet (HandoffPacket.brief) on its first turn. ACP takes it as an
  /// embedded resource on every turn it rides; every other engine reads it ahead of `volatile`.
  public var packet: Embedded? = nil
  public struct Embedded: Hashable, Sendable {
    public var uri: String
    public var text: String
    public init(uri: String, text: String) {
      self.uri = uri
      self.text = text
    }
  }
  public init(stable: String, volatile: String, message: String, recovery: String?) {
    self.stable = stable
    self.volatile = volatile
    self.message = message
    self.recovery = recovery
  }
  /// The slice and the packet moved into `volatile`; `stable` is never touched, so the warm key holds.
  public var contextInVolatile: TurnPrompt {
    guard registry != nil || packet != nil else { return self }
    var moved = self
    moved.volatile = [registry ?? "", packet?.text ?? "", volatile].filter { !$0.isEmpty }.joined(separator: "\n\n")
    moved.registry = nil
    moved.packet = nil
    return moved
  }
}

public struct BrowserServer: Hashable, Sendable {
  public var command: URL
  public var arguments: [String]
  public var tools: [String]
  public init(command: URL, arguments: [String], tools: [String]) {
    self.command = command
    self.arguments = arguments
    self.tools = tools
  }
}

public struct TurnHandle: Sendable {
  /// Always ends with exactly one `.ended`.
  public let events: AsyncStream<EngineEvent>
}

/// What a turn reports. Text is untrusted.
public enum EngineEvent: Sendable, Equatable {
  /// `rebuilt`: the CLI refused `resume` and a new session started from `prompt.recovery`.
  case session(id: String, rebuilt: Bool)
  case text(String)
  case thinking(String)
  /// Text after this is a new message: what came before was narration between tools.
  case newMessage
  case toolStarted(id: String, name: String, detail: String)
  case toolEnded(id: String, result: ToolResult)
  /// The harness sends the turn again itself; the half answer no longer counts.
  case retrying(attempt: Int, after: Duration, reason: String)
  /// The CLI asked and Serein said no at a level below Full. Never emitted for a task.
  case declined(PendingApprovalValue)
  /// The CLI asked and Serein answered with no approval to show: allowed once, or refused (Full,
  /// a task, or a rule outside Project-mode edits). For the behaviour history.
  case permissionAnswered(allowed: Bool)
  /// Quiet notice ("The CLI has sent nothing for 60 s.").
  case notice(String)
  /// The app's usage limit refused a request (LimitFailover reads it when the turn fails).
  case limitReached(UsageLimit)
  /// The provider's own count of the share it has left, 0 to 1 (UsageTally reads it when the turn ends).
  case usageLeft(Double)
  /// The CLI has not started: the Mac is short of memory (EngineRoom). The run is waiting, not silent.
  case waiting(String)
  case usage(input: Int, output: Int, cachedInput: Int?)
  /// How full the CLI's context is. `estimated` when the CLI reports nothing and Serein counted
  /// characters instead.
  case context(used: Int, size: Int?, estimated: Bool)
  /// The session commands the CLI advertises for this session (ACP `available_commands_update`).
  case commands([SlashCommand])
  case ended(TurnEnd)
}

public enum ToolResult: Sendable, Equatable {
  case ok, failed
  /// Cut mid-call; never assumed done.
  case unknown
}

/// SereinCore.PendingApproval as a Sendable value.
public struct PendingApprovalValue: Sendable, Equatable {
  public var id, tool, target: String
  public init(id: String, tool: String, target: String) {
    self.id = id
    self.tool = tool
    self.target = target
  }
}

/// How a turn ended. Only the reason is stored and `outcome` is derived from it, so a
/// `.maxTokens` end can never show as completed.
public struct TurnEnd: Sendable, Equatable {
  public let stopReason: StopReason
  public var sessionID: String?
  public var outcome: Outcome { Outcome(stopReason) }
  public init(_ stopReason: StopReason, sessionID: String? = nil) {
    self.stopReason = stopReason
    self.sessionID = sessionID
  }
}

public enum StopReason: Error, Sendable, Equatable {
  case endTurn
  case maxTokens
  /// The model refused.
  case refusal
  /// The same call repeated (HarnessLoopGuard).
  case loop(tool: String)
  /// Silent with no sign of work (HarnessStuck), after this many seconds of silence.
  case stuck(seconds: Int)
  /// The person pressed Stop.
  case stopped
  /// Read-back failed on the named value; the process was ended.
  case modeMismatch(name: String, expected: String, reported: String?)
  case signIn(String)
  /// Raw text kept; `UsageLimit` reads the reset time from it.
  case usageLimit(String)
  case failed(String)
  /// The `finish` tool ended the turn.
  case finished
  /// The turn used its `stepBudget`.
  case stepLimit(Int)
  /// The API key was refused (not a signed-out subscription).
  case keyFailure(String)
  case modelRejected(String)
  case offline(String)
  /// The CLI could not load the session to resume, and no rebuild was possible.
  case resumeFailed(String)
  /// The CLI's own rules declined this step (a Codex decline, Grok's refused ask; R33). The text names the step.
  case declined(String)
}

public enum Outcome: Sendable, Equatable {
  case completed, cutShort, stopped, failed
  init(_ reason: StopReason) {
    switch reason {
    case .endTurn, .finished: self = .completed
    case .maxTokens, .loop, .stuck, .stepLimit, .declined: self = .cutShort
    case .stopped: self = .stopped
    case .refusal, .modeMismatch, .signIn, .usageLimit, .failed, .keyFailure, .modelRejected, .offline, .resumeFailed:
      self = .failed
    }
  }
}

public enum SteerOutcome: Sendable, Equatable {
  case steered, refused
  /// Maybe delivered: never re-queue.
  case indeterminate
  /// Not delivered: the CLI cannot take words mid-turn, or the turn just ended (30 s grace).
  /// The caller sends them as the next turn.
  case handedBack(String)
}

public enum Readiness: Sendable, Equatable {
  case ready(version: String)
  case needsSignIn(String)
  case needsUpdate(have: String, need: String)
  case missing
  case broken(String)
}

/// Thrown by `send` before any process starts.
public enum EngineRefusal: Error, Sendable, Equatable {
  /// The CLI cannot honour this access (no read-only mode it can prove, say).
  case cliCannot(Access)
  case versionTooOld(have: String, need: String)
  case notReady(Readiness)
  /// The thread already runs a turn. AgentHub queues, so this is a caller bug.
  case threadBusy
  /// `revalidate` found the CLI signed out or its binary changed.
  case needsRepair(String)
}
