import Foundation

/// The one door. Every "run, card or blocked" for a step is answered here, from one request and
/// what code saw (`Facts`). Code says no only at a `Boundary`; every other decision is the
/// model's, made from the shared prompt section (arena/decisions/DESIGN.md). Code outside this
/// file reaches it only through `answer` (scripts/check_approval_door.py).
public enum ApprovalDoor {
  /// Who is asking, for one turn of one chat.
  public struct Standing: Equatable, Sendable {
    public var level: ApprovalLevel
    /// The person started this turn. False in a scheduled run and when Serein speaks first. At
    /// Manual a card then defers instead of holding the call.
    public var levelStands: Bool
    /// Somebody is there to answer a card. False in a schedule, a watch or a webhook.
    public var present: Bool
    /// Scheduled, relay or self-started. Allow all runs it as it runs an attended turn (R15).
    public var unattended: Bool

    public init(level: ApprovalLevel, levelStands: Bool, present: Bool, unattended: Bool? = nil) {
      self.level = level
      self.levelStands = levelStands
      self.present = present
      self.unattended = unattended ?? !present
    }

    /// The person's own turn at `level`, with them there.
    public static func person(_ level: ApprovalLevel) -> Standing {
      Standing(level: level, levelStands: true, present: true)
    }
    /// No chat stands behind the step, so no level does: a changing step shows a card.
    public static func noChat(present: Bool) -> Standing {
      Standing(level: .everyStep, levelStands: false, present: present)
    }
    /// A task the person asked Serein to run, at Allow all.
    public static func proactiveTask(present: Bool) -> Standing {
      Standing(level: .proactive, levelStands: true, present: present)
    }
    /// The same turn at Auto. For the card that offers that level in place; it decides no step.
    public var atRiskyOnly: Standing {
      Standing(level: .riskyOnly, levelStands: true, present: present, unattended: unattended)
    }
  }

  public enum Step {
    case effect(ApprovalGate.Effect)
    case action(ApprovalGate.GateAction)
    case macStep(RelayAutonomy.MacStep)
    case script(String)
    case setting(tool: String, action: String = "")
    /// Calendar, Reminders, Contacts, Notes. `yesWaits`: Allow on a deferred card waits in the chat.
    case nativeConnection(tool: String, yesWaits: Bool = false)
    case plugin(name: String, declared: PluginManifest.Risk?, effect: ApprovalGate.Effect? = nil)
    case command(String, mode: LocalExecution.Mode)
    case mail(Connections.Tool, scheduledAllowed: Bool = false)
    /// One act on the person's own other machine.
    case ownMachine(tool: String, key: String?, text: String?)
    /// Downloads from a new site in a task.
    case downloads
  }

  public enum PaySense: Sendable, Equatable {
    case no
    case yes(amount: String?)
    /// The page could not be read, so it may pay (R30).
    case unreadable
  }

  public enum PathPlace: Sendable, Equatable {
    // Outside the folder is the sandbox's to close (AgentFileGuard); a widening opens it there (PathGrants.roots).
    case inside, privateStore
  }

  /// What code saw, never what the model said. No default init, so no caller forgets a sensor
  /// (R30). The door adds what the step itself shows (a secure field's role, a secrets app, a
  /// paying effect).
  public struct Facts: Sendable, Equatable {
    public let secureField: Bool
    public let botCheck: Bool
    public let pays: PaySense
    /// The person's secure card or a grant already covers this exact step (R24).
    public let covered: Bool
    public let path: PathPlace?
    public let hostKeyChanged: String?
    /// Terminal, iTerm, Script Editor, Automator, Shortcuts, osascript outside mac_run (R29).
    public let runsAnything: Bool
    /// The button the pay route names (R1).
    public let ref: String
    public init(
      secureField: Bool, botCheck: Bool, pays: PaySense, covered: Bool, path: PathPlace?, hostKeyChanged: String?,
      runsAnything: Bool, ref: String
    ) {
      self.secureField = secureField
      self.botCheck = botCheck
      self.pays = pays
      self.covered = covered
      self.path = path
      self.hostKeyChanged = hostKeyChanged
      self.runsAnything = runsAnything
      self.ref = ref
    }
  }

  public struct Request: Sendable {
    public var step: Step
    public var standing: Standing
    /// The person's rule for the site.
    public var site: SiteRule
    public var taskID: String?

    public init(_ step: Step, _ standing: Standing, site: SiteRule = .normal, taskID: String? = nil) {
      self.step = step
      self.standing = standing
      self.site = site
      self.taskID = taskID
    }
  }

  public enum CardWait: Sendable, Equatable {
    /// Manual, the person there, the level standing: the card holds the call up to `cap` (R15).
    case hold(cap: Duration)
    /// The card stays open and the tool answers asked.
    case deferred
  }

  public enum Answer: Sendable, Equatable {
    case run
    case card(CardWait)
    /// The journal cannot tell whether this step already ran: told once, the same call again runs.
    case checkFirst(String)
    case blocked(Boundary)

    /// The text a tool answers with instead of running, as a normal result: the Blocked line or
    /// the journal's check line. nil for run and card.
    public var said: String? {
      switch self {
      case .run, .card: return nil
      case .checkFirst(let line): return line
      case .blocked(let boundary): return boundary.blocked?.text
      }
    }
    public var runs: Bool { self == .run }
    public var asks: Bool {
      if case .card = self { return true }
      return false
    }

    /// For a caller whose own path still shows its card: `.auto` runs, `.ask` shows the card.
    /// A said line is thrown (`Blocked` or `CheckFirst`), and the tool socket answers it as a
    /// normal result (R17).
    public func decision() throws -> RelayAutonomy.Decision {
      switch self {
      case .run: return .auto
      case .card: return .ask
      case .checkFirst(let line): throw CheckFirst(text: line)
      case .blocked(let boundary):
        guard let blocked = boundary.blocked else { return .ask }
        throw blocked
      }
    }
  }

  /// The journal's check line, thrown by `Answer.decision()` so a deep site's step stops there
  /// and the line reaches the model as a normal result.
  public struct CheckFirst: Error, Sendable, Equatable, LocalizedError {
    public let text: String
    public var errorDescription: String? { text }
  }

  /// The smallest CLI call cap (Cursor, 118 s) minus 10 s. The door does not know the CLI.
  public static let holdCap: Duration = .seconds(108)

  /// The one door. Reads all of Standing; Allow all unattended runs as attended (R15).
  public static func answer(_ request: Request, facts: Facts) -> Answer {
    if let boundary = boundary(request, facts) {
      guard boundary == .siteAsk else { return .blocked(boundary) }
      return reads(request.step) ? journaled(request) : .card(wait(request.standing))
    }
    if request.standing.level == .everyStep, !reads(request.step) { return .card(wait(request.standing)) }
    return journaled(request)
  }

  /// From the tool kind, never from words. Every command counts as a change (R15).
  public static func reads(_ step: Step) -> Bool {
    if case .command = step { return false }
    return [.read, .scroll, .navigate].contains(effect(of: step))
  }

  /// Apps where one keystroke runs any command (R29), driven through Mac control. System
  /// Settings is not one of them: settings run (owner, wave 1).
  public static func runsAnything(app: String) -> Bool {
    let name = app.lowercased().trimmingCharacters(in: .whitespaces)
    return LocalExecution.terminals.contains(name) || ["script editor", "automator", "shortcuts"].contains(name)
  }

  /// The floor, in a fixed order. Found from structure, never from what a step's words mean.
  static func boundary(_ request: Request, _ facts: Facts) -> Boundary? {
    if request.site == .never { return .siteNever }
    if facts.path == .privateStore || holdsSecrets(request.step) { return .privateStore }
    if facts.runsAnything { return .codeRunner }
    if facts.secureField || secretField(request.step) { return .secret }
    if facts.botCheck { return .botCheck }
    if let host = facts.hostKeyChanged { return .hostKey(host: host) }
    if facts.pays != .no || effect(of: request.step) == .pay, !facts.covered { return .pay(ref: facts.ref) }
    if request.site == .ask { return .siteAsk }
    return nil
  }

  private static func wait(_ standing: Standing) -> CardWait {
    standing.present && standing.levelStands ? .hold(cap: holdCap) : .deferred
  }

  /// Inside a tool call the journal hears every step that would run: a change is written down
  /// first. One whose earlier outcome is unknown is told once; the same call again runs. A
  /// journal that cannot write logs it and the step runs (R15, R19).
  private static func journaled(_ request: Request) -> Answer {
    guard let live = StepJournal.live else { return .run }
    let effect = effect(of: request.step)
    var written = live.decided(effect, .auto)
    if written == .ask, let stuck = live.stuck {
      if told.insert(stuck.id) {
        return .checkFirst("Serein cannot tell whether \(stuck.tool) already ran. Check, then call it again if it did not.")
      }
      written = live.allowed() ? .auto : .refuse
    }
    if written == .refuse {
      NSLog("Serein: the step journal could not write %@ down; the step runs", effect.rawValue)
    }
    return .run
  }
  private static let told = Told()
  private final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()
    func insert(_ id: String) -> Bool { lock.withLock { ids.insert(id).inserted } }
  }

  private static func gateAction(_ step: Step) -> ApprovalGate.GateAction? {
    switch step {
    case .action(let action): return action
    case .macStep(let step): return ApprovalGate.gateAction(step)
    default: return nil
    }
  }
  private static func holdsSecrets(_ step: Step) -> Bool {
    guard let app = gateAction(step)?.app?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
    return RelayAutonomy.holdsSecrets(app: app, bundleID: nil)
  }
  /// Typing into a secure field, or a field whose own label says password ("Show password" turns
  /// a secure field into a plain one, so the role alone misses it).
  private static func secretField(_ step: Step) -> Bool {
    if case .command(let source, _) = step { return LocalExecution.effect(of: source) == .access }
    if case .script(let source) = step { return ApprovalGate.scriptAsksPassword(source) }
    // On the person's own machine: a command or typed text that takes root or a password
    // (sudo, su, passwd, an administrator prompt). Only the person types that password.
    if case .ownMachine(let tool, _, let text?) = step {
      let root = LocalExecution.effect(of: text) == .access
      return tool == "computer_type" ? root : tool == "computer_run" && (root || ApprovalGate.scriptAsksPassword(text))
    }
    guard let action = gateAction(step) else { return false }
    if action.role == "AXSecureTextField" { return true }
    if (action.app == "System Settings" || action.app == "System Preferences"), action.kind == "click",
       action.label?.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).lowercased() == "change password" {
      return true
    }
    guard action.kind == "type", let label = action.label?.lowercased() else { return false }
    return ["password", "passcode", "passphrase"].contains { label.contains($0) }
  }

  /// What the step would do, from one classifier per kind of step. A command, and text typed
  /// into a terminal, are read as commands (`LocalExecution.effect`). The step journal reads it: an effect that
  /// changes something is written down before it runs (`StepJournal.isChange`).
  public static func effect(of step: Step) -> ApprovalGate.Effect {
    switch step {
    case .effect(let effect): return effect
    case .action(let action): return effect(of: action)
    case .macStep(let step): return effect(of: ApprovalGate.gateAction(step))
    case .script(let source): return ApprovalGate.scriptEffect(source: source)
    case .setting(let tool, let action): return ApprovalGate.settingsEffect(tool: tool, action: action)
    case .nativeConnection(let tool, _): return NativeConnection.effect(tool: tool) ?? .unknown
    case .plugin(let name, let declared, let effect):
      // Missing metadata cannot clear independent payment evidence from the tool's name or structure.
      if declared == nil {
        return ApprovalGate.pluginEffect(name: name, declared: .read, effect: effect) == .pay ? .pay : .unknown
      }
      return ApprovalGate.pluginEffect(name: name, declared: declared, effect: effect) ?? .unknown
    case .command(let command, _): return LocalExecution.effect(of: command)
    case .mail(let tool, _): return tool.effect ?? .read
    case .ownMachine, .downloads: return .unknown
    }
  }

  private static func effect(of action: ApprovalGate.GateAction) -> ApprovalGate.Effect {
    let app = action.app?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
    if action.kind == "type", let text = action.text, LocalExecution.terminals.contains(app) {
      return LocalExecution.effect(of: text)
    }
    return action.effect ?? ApprovalGate.resolved(action)
  }
}
