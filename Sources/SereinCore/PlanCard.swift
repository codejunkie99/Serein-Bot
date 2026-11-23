import Foundation

/// The plan card (SPEC 2.6, unit A16): live work of two to seven steps that the model names with
/// the `plan` tool. Titles are the model's words, so each is one line of at most `titleLimit`
/// characters with no feature word; the live sub-step under the current step is the host's step
/// word for the tool call in flight, never the model's or a page's. Steps only move forward: a
/// step starts, ends, fails, waits for the person or is skipped, and never goes back. Pure: the
/// shell keeps one card per chat and lands it on the turn's reply when the turn ends.
public struct PlanCard: Codable, Equatable, Sendable {
  public enum Effect: String, Codable, CaseIterable, Sendable { case read, change, send, buy, delete }
  public enum State: String, Codable, Equatable, Sendable { case next, current, waiting, done, failed, declined, skipped }
  public struct Step: Codable, Equatable, Sendable {
    public var title: String
    public var effect: Effect?
    public var state: State
    public init(title: String, effect: Effect? = nil, state: State = .next) {
      self.title = title
      self.effect = effect
      self.state = state
    }
  }
  public enum Problem: Error, Equatable, Sendable {
    case tooFew, tooMany
    /// A title is longer than `titleLimit` characters. Steps count from 1.
    case tooLong(step: Int)
    /// A title is not one line of plain words.
    case plainWords(step: Int)
    /// A move would go back, or names a step that does not exist.
    case backwards
    /// A move came before any steps.
    case noPlan

    public var words: String {
      switch self {
      case .tooFew: return "A plan has at least \(PlanCard.minSteps) steps."
      case .tooMany: return "A plan has at most \(PlanCard.maxSteps) steps."
      case .tooLong(let step): return "Step \(step) is longer than \(PlanCard.titleLimit) characters. Say it shorter."
      case .plainWords(let step): return "Step \(step) must be one line of plain words."
      case .backwards: return "A plan only moves forward: a step that ended cannot start again, and steps count from 1."
      case .noPlan: return "Give the steps first."
      }
    }
  }

  public static let minSteps = 2
  public static let maxSteps = 7
  public static let titleLimit = 40
  /// A plan with no move for this long while its turn runs folds by itself.
  public static let idleFold: TimeInterval = 300

  public private(set) var steps: [Step]
  public private(set) var startedAt: Date
  public private(set) var lastMove: Date
  /// Set when the turn ended or the plan sat idle: the card shows its folded line.
  public private(set) var endedAt: Date?

  public init(steps: [Step], now: Date) {
    self.steps = steps
    startedAt = now
    lastMove = now
  }

  /// `steps` (2 to 7 of `title` and an optional `effect`), then moves by step number (from 1):
  /// `now` starts a step (the one before it ends), `done`, `failed` and `skipped` end one. New
  /// steps may replace the plan only while no step has started; a move without steps needs
  /// `previous`.
  public static func parse(_ arguments: [String: Any], previous: PlanCard?, now: Date = Date()) -> Result<PlanCard, Problem> {
    var card: PlanCard
    if let raw = arguments["steps"] as? [Any] {
      var steps: [Step] = []
      for (index, item) in raw.enumerated() {
        let fields: [String: Any] = item as? [String: Any] ?? [:]
        let title: String = ((fields["title"] as? String) ?? (item as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = titleProblem(title, step: index + 1) { return .failure(problem) }
        let effect: Effect? = (fields["effect"] as? String).flatMap { Effect(rawValue: $0.lowercased()) }
        steps.append(Step(title: title, effect: effect))
      }
      guard steps.count >= minSteps else { return .failure(.tooFew) }
      guard steps.count <= maxSteps else { return .failure(.tooMany) }
      if let previous {
        guard previous.steps.allSatisfy({ $0.state == .next }) else { return .failure(.backwards) }
        card = PlanCard(steps: steps, now: previous.startedAt)
      } else {
        card = PlanCard(steps: steps, now: now)
      }
    } else {
      guard let previous else { return .failure(.noPlan) }
      card = previous
    }
    if let problem = card.applyMoves(arguments) { return .failure(problem) }
    card.lastMove = now
    return .success(card)
  }

  /// The index (from 0) of the step that runs now.
  public var current: Int? { steps.firstIndex { $0.state == .current || $0.state == .waiting } }

  /// The step shows "Asks first": its effect sends, buys or deletes, or the gate asked during it.
  /// A missing badge never skips a card; the gate still decides.
  public func asksFirst(_ index: Int, gateAsked: Bool) -> Bool {
    guard steps.indices.contains(index) else { return false }
    if gateAsked { return true }
    switch steps[index].effect {
    case .send?, .buy?, .delete?: return true
    case .read?, .change?, nil: return false
    }
  }

  /// The gate asks the person during the step that runs: it waits for them.
  public mutating func waitForPerson(now: Date) {
    guard let i = current, steps[i].state == .current else { return }
    steps[i].state = .waiting
    lastMove = now
  }
  /// The person answered: a yes runs on, a no marks the step declined.
  public mutating func answered(allowed: Bool, now: Date) {
    guard let i = current, steps[i].state == .waiting else { return }
    steps[i].state = allowed ? .current : .declined
    lastMove = now
  }
  /// The turn ended, or no move came for `idleFold` seconds: the card folds.
  public mutating func end(now: Date) {
    guard endedAt == nil else { return }
    endedAt = now
  }
  public func idle(now: Date) -> Bool { endedAt == nil && now.timeIntervalSince(lastMove) >= Self.idleFold }

  /// "12s", "1m 04s", "1h 02m".
  public static func elapsed(_ seconds: Int) -> String {
    let total = max(0, seconds)
    if total < 60 { return "\(total)s" }
    if total < 3_600 {
      let minutes = total / 60
      let rest = total % 60
      return "\(minutes)m " + (rest < 10 ? "0" : "") + "\(rest)s"
    }
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    return "\(hours)h " + (minutes < 10 ? "0" : "") + "\(minutes)m"
  }
  /// The folded line: "Did 5 steps in 2m 10s.", "Stopped at step 3 of 5: Check every number.",
  /// or "Did 3 of 5 steps." for a plan that ended before its last step.
  public func folded(seconds: Int) -> String {
    let total = steps.count
    if steps.allSatisfy({ $0.state == .next }) { return "Proposed a plan of \(total) step\(total == 1 ? "" : "s")." }
    if let failed = steps.firstIndex(where: { $0.state == .failed }) {
      return "Stopped at step \(failed + 1) of \(total): \(steps[failed].title)."
    }
    let finished = steps.filter { $0.state == .done || $0.state == .skipped }.count
    let done = steps.filter { $0.state == .done }.count
    if finished == total { return "Did \(done) step\(done == 1 ? "" : "s") in \(Self.elapsed(seconds))." }
    return "Did \(done) of \(total) steps."
  }

  // MARK: moves

  /// Applies `now`, `done`, `failed` and `skipped`; the problem when one would go back.
  mutating func applyMoves(_ a: [String: Any]) -> Problem? {
    for index in Self.numbers(a["done"]) {
      guard let problem = end(index, as: .done) else { continue }
      return problem
    }
    for index in Self.numbers(a["failed"]) {
      guard let problem = end(index, as: .failed) else { continue }
      return problem
    }
    for index in Self.numbers(a["skipped"]) {
      guard let problem = end(index, as: .skipped) else { continue }
      return problem
    }
    if let start = Self.numbers(a["now"]).first {
      let i = start - 1
      guard steps.indices.contains(i) else { return .backwards }
      let state = steps[i].state
      if state == .current || state == .waiting { return nil }
      guard state == .next else { return .backwards }
      // The step that ran ends as done; earlier steps that never started are skipped.
      for j in 0..<i {
        if steps[j].state == .current || steps[j].state == .waiting {
          steps[j].state = .done
        } else if steps[j].state == .next {
          steps[j].state = .skipped
        }
      }
      steps[i].state = .current
    }
    return nil
  }
  /// Ends step `number` (from 1) as `state`, once.
  mutating func end(_ number: Int, as state: State) -> Problem? {
    let i = number - 1
    guard steps.indices.contains(i) else { return .backwards }
    let before = steps[i].state
    if before == state { return nil }
    guard before == .next || before == .current || before == .waiting else { return .backwards }
    steps[i].state = state
    return nil
  }
  /// One number or a list of numbers.
  static func numbers(_ value: Any?) -> [Int] {
    if let one = value as? Int { return [one] }
    if let list = value as? [Int] { return list }
    if let many = value as? [Any] { return many.compactMap { $0 as? Int } }
    return []
  }
  /// nil when `title` can be a step: one line, 1 to `titleLimit` characters, no feature word.
  static func titleProblem(_ title: String, step: Int) -> Problem? {
    if title.isEmpty || !TeamProposal.oneLine(title) { return .plainWords(step: step) }
    if title.count > titleLimit { return .tooLong(step: step) }
    let words = Set(title.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    if !ReceiptCopy.bannedWords.isDisjoint(with: words) { return .plainWords(step: step) }
    return nil
  }
}
