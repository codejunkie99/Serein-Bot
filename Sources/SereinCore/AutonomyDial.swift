import Foundation

/// The Permissions view's table (affectUI Autonomy Dial): real actions, each judged by the same
/// gate the action itself passes (`ApprovalDoor.answer`), so the view can never say Serein does
/// more on its own than the gate lets it. The dial only reads the level; it never sets one.
public enum AutonomyDial {
  public struct Action: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// The step the gate judges for this row.
    public let probe: ApprovalGate.GateAction
    public let risk: ApprovalRisk
    init(_ id: String, _ title: String, _ probe: ApprovalGate.GateAction, risk: ApprovalRisk? = nil) {
      self.id = id
      self.title = title
      self.probe = probe
      self.risk = risk ?? ApprovalRisk.of(probe.effect ?? .unknown)
    }
    init(_ id: String, _ title: String, _ effect: ApprovalGate.Effect) {
      self.init(id, title, ApprovalGate.GateAction(kind: "click", label: "Next", effect: effect))
    }
  }

  /// Where a row sits at one level. `alwaysAsks` and `never` are hard stops: the same at every level.
  public enum Place: Equatable, Sendable { case alone, asks, alwaysAsks, never }

  public static let actions: [Action] = [
    Action("read", "Read and scroll pages", ApprovalGate.GateAction(kind: "scroll", effect: .scroll)),
    Action("navigate", "Move between pages", .navigate),
    Action("click", "Click buttons and links", .click),
    Action("type", "Type into fields", ApprovalGate.GateAction(kind: "type", effect: .type)),
    // The effects `RelayToolHost.runEffect` gives a run that only answers, and one that acts.
    Action("answer", "Start a task that only answers", .navigate),
    Action("task", "Start a task that works in pages, files or apps", .change),
    Action("send", "Send a message", .send),
    Action("post", "Post", .post),
    Action("pay", "Buy or pay", .pay),
    Action("delete", "Delete", .delete),
    Action("submit", "Submit a form", .submit),
    Action("fill", "Fill in saved details", .fill),
    Action("book", "Book", .book),
    Action("access", "Sign in, sign out or share access", .access),
    Action("settings", "Change a setting", .settings),
    Action("install", "Install or remove apps", .install),
    Action("upload", "Send a file from your Mac", .upload),
    Action("terminal", "Use Terminal or System Settings",
           ApprovalGate.GateAction(kind: "click", label: "Next", app: "Terminal", effect: .click), risk: .high),
    Action("password", "Type into password fields",
           ApprovalGate.GateAction(kind: "type", role: "AXSecureTextField", effect: .type), risk: .high),
    Action("passwordApps", "Open password managers",
           ApprovalGate.GateAction(kind: "click", label: "Next", app: "1Password", effect: .click), risk: .high),
  ]

  /// The door's answer for the row's step at `level`, with the facts that step shows.
  public static func decision(_ action: Action, at level: ApprovalLevel) -> ApprovalDoor.Answer {
    ApprovalDoor.answer(
      .init(.action(action.probe), .person(level)),
      facts: .init(
        secureField: false, botCheck: false, pays: .no,
        covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: ApprovalDoor.runsAnything(app: action.probe.app ?? ""), ref: ""))
  }

  /// The door gives it the same answer at every level, and that answer is never “go ahead”.
  public static func locked(_ action: Action) -> Bool {
    let answers = ApprovalLevel.chatChoices.map { decision(action, at: $0) }
    return answers.allSatisfy { $0 == answers.first } && !answers.contains(where: \.runs)
  }

  public static func place(_ action: Action, at level: ApprovalLevel) -> Place {
    switch decision(action, at: level) {
    // Paying is the person's own card at every level; the rest of the floor Serein never does.
    case .blocked(.pay): return .alwaysAsks
    case .blocked: return .never
    case .card: return locked(action) ? .alwaysAsks : .asks
    case .run, .checkFirst: return .alone
    }
  }

  public static func actions(_ place: Place, at level: ApprovalLevel) -> [Action] {
    actions.filter { self.place($0, at: level) == place }
  }

  /// Read out when the level changes (affectUI's polite announcement).
  public static func announcement(at level: ApprovalLevel) -> String {
    let alone = actions(.alone, at: level).count
    let asks = actions(.asks, at: level).count + actions(.alwaysAsks, at: level).count
    return "\(level.title). On its own: \(alone). Asks first: \(asks)."
  }
}
