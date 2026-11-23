import Foundation

/// Words typed while a turn runs, and a turn the person stopped. The words go into the running
/// turn when its wire takes words mid-turn, else with the next turn. Neither path stops anything,
/// and neither widens what the running turn may do: its grants and the consent words it reads
/// were fixed when it started. Stop and use now stays for people who want the turn cut short.
public enum RunSteering {
  public enum Path: Equatable, Sendable { case intoTurn, nextTurn }

  /// The one decision. `wire` nil is Serein's own model loop (a direct provider connection). Every wire states its
  /// path here; a new wire does not compile until it does.
  public static func path(
    _ wire: HarnessDriver.Wire?, carriesContext: Bool, othersWaiting: Bool, byPerson: Bool
  ) -> Path {
    // Chips stay with a waiting message, earlier waiting words keep send order, and only the
    // person's own words enter their turn, never automation.
    guard !carriesContext, !othersWaiting, byPerson else { return .nextTurn }
    switch wire {
    case nil: return .intoTurn  // Serein's loop reads them at its next round.
    case .claudeStream?: return .intoTurn  // A stream-json line on open stdin (measured 2.1.325).
    case .codexAppServer?: return .intoTurn  // turn/steer (0.169.0); `codex exec` hands them back.
    case .acp?: return .nextTurn  // One session/prompt per turn.
    case .piJSON?: return .intoTurn  // rpc `steer`: read after the running tool ends.
    }
  }

  /// The composer's line while a step runs and words are typed: the offer, in the chat.
  public static func hint(_ path: Path, app: String) -> String {
    switch path {
    case .intoTurn: return "Return sends this to \(app) now. It keeps working."
    case .nextTurn: return "Return sends this when \(app) finishes this step."
    }
  }
  /// Under words written into the turn and not read yet.
  public static func sent(app: String) -> String { "Sent. \(app) reads it after this step." }
  /// Under words that wait for the next turn.
  public static let nextStep = "Goes with the next step"
  public static func useNow(several: Bool) -> String { several ? "Stop and use all now" : "Stop and use now" }
  /// After Stop: the turn picks up where it was, with nothing typed.
  public static let resume = "Resume"
  public static let resumeWords = "I stopped you before you finished. Keep the work already done and carry on from where you stopped."
  /// Resume shows once a turn was stopped and nothing runs, while the box is empty: words typed
  /// there are what goes next instead.
  public static func offersResume(stopped: Bool, running: Bool, typed: Bool) -> Bool {
    stopped && !running && !typed
  }
}

/// Words written into one running turn, until the engine reads them. Owned by the run.
public struct SteerLedger: Equatable, Sendable {
  /// `shown` is what the person typed (their bubble); `wire` is what went to the engine.
  public struct Line: Equatable, Sendable {
    public let shown: String
    public let wire: String
    public init(shown: String, wire: String) {
      self.shown = shown
      self.wire = wire
    }
  }
  public private(set) var waiting: [Line] = []
  public init() {}

  public mutating func wrote(_ line: Line) { waiting.append(line) }

  /// For engines Serein drives itself (Codex app server, Local model): the oldest waiting line.
  public mutating func take() -> Line? { waiting.isEmpty ? nil : waiting.removeFirst() }
  /// At run end: the person's words the engine never read, oldest first. Empties the ledger.
  public mutating func leftovers() -> [String] {
    defer { waiting = [] }
    return waiting.map(\.shown)
  }
}
