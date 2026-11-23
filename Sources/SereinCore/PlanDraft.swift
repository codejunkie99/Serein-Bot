import Foundation

/// With plan first on, the plan a turn proposed, before anything runs: the person drops, reorders
/// and rewords its steps, then Start approves it. The steps come from the turn's plan card while
/// none has started, else from the reply's first numbered list. Unchanged, Start sends "Go ahead",
/// the approval phrase as typed; changed, it sends `edited` and the steps in their new order,
/// which `approves` also takes, so either way it is the same one-reply grant the plan asked for
/// and nothing else. Pure: the view keeps one draft and sends `message`.
public struct PlanDraft: Equatable, Sendable {
  public struct Step: Equatable, Identifiable, Sendable {
    /// The step's place in the proposed plan, from 1; it stays with the step when it moves.
    public let id: Int
    public var title: String
  }

  public private(set) var steps: [Step]
  /// The titles as proposed, in order: what "changed" is measured against.
  public let proposed: [String]

  /// The plan's steps, at most this many from a reply's list.
  public static let maxSteps = 12
  /// A reworded step is one line of at most this many characters.
  public static let titleLimit = 200
  /// The approval of an unchanged plan.
  public static let unchanged = "Go ahead"
  /// The first line of a changed plan's approval; the numbered steps follow, one a line.
  public static let edited = "Go ahead, with the plan changed to these steps, in this order:"

  public init(titles: [String]) {
    proposed = titles
    steps = titles.enumerated().map { Step(id: $0.offset + 1, title: $0.element) }
  }

  /// The plan card's steps while none has started; nil once one has.
  public init?(plan: PlanCard) {
    guard plan.steps.count >= 2, plan.steps.allSatisfy({ $0.state == .next }) else { return nil }
    self.init(titles: plan.steps.map(\.title))
  }

  /// The reply's first numbered list ("1." or "1)" at a line's start), counting 1, 2, 3 in turn;
  /// lines between its items (a step's files) stay with the reply, not the card. Nil for fewer
  /// than two steps or more than `maxSteps`.
  public init?(reply: String) {
    var titles: [String] = []
    for raw in reply.split(separator: "\n", omittingEmptySubsequences: false) {
      guard let item = Self.item(String(raw)) else { continue }
      if item.number == titles.count + 1 {
        titles.append(item.title)
      } else if !titles.isEmpty {
        break
      }
    }
    guard titles.count >= 2, titles.count <= Self.maxSteps else { return nil }
    self.init(titles: titles)
  }

  public var changed: Bool { steps.map(\.title) != proposed }

  /// Why Start cannot go yet, in words; nil when it can.
  public var problem: String? {
    if steps.isEmpty { return "Keep at least one step, or tell Serein what to do instead." }
    if let blank = steps.firstIndex(where: { $0.title.isEmpty }) { return "Step \(blank + 1) needs words, or drop it." }
    return nil
  }

  /// What Start sends; nil while `problem` holds.
  public var message: String? {
    guard problem == nil else { return nil }
    guard changed else { return Self.unchanged }
    return ([Self.edited] + steps.enumerated().map { "\($0.offset + 1). \($0.element.title)" }).joined(separator: "\n")
  }

  public mutating func drop(_ id: Int) { steps.removeAll { $0.id == id } }

  /// Moves the step one place up (`by: -1`) or down (`by: 1`); at either end it stays.
  public mutating func move(_ id: Int, by offset: Int) {
    guard let from = steps.firstIndex(where: { $0.id == id }) else { return }
    let to = from + offset
    guard steps.indices.contains(to) else { return }
    steps.swapAt(from, to)
  }

  /// The step's new words: one line, trimmed, at most `titleLimit` characters.
  public mutating func rename(_ id: Int, to title: String) {
    guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
    let line = title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    steps[i].title = String(line.prefix(Self.titleLimit))
  }

  /// Every step back as proposed.
  public mutating func reset() { self = PlanDraft(titles: proposed) }

  /// What a screen reader hears after a move: "Moved “Check the copy” to step 3 of 5."
  public func moved(_ id: Int) -> String? {
    guard let i = steps.firstIndex(where: { $0.id == id }) else { return nil }
    return "Moved “\(steps[i].title)” to step \(i + 1) of \(steps.count)."
  }

  /// The person approved a plan: an approval phrase (`PageContext.isApproval`), or `edited` on its
  /// own first line with only steps numbered 1, 2, 3 in turn after it.
  public static func approves(_ text: String) -> Bool {
    if PageContext.isApproval(text) { return true }
    let lines: [String] = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.count >= 2, lines[0] == edited else { return false }
    for (index, line) in lines.dropFirst().enumerated() {
      guard let item = item(line), item.number == index + 1, !item.title.isEmpty else { return false }
    }
    return true
  }

  /// "3. Check every number" or "3) **Check** every number": its number and its words, emphasis
  /// marks dropped. At most three spaces before the number, so a nested list is not read.
  static func item(_ line: String) -> (number: Int, title: String)? {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3 else { return nil }
    let rest = line.dropFirst(indent)
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    guard (1...2).contains(digits.count), let number = Int(digits) else { return nil }
    let after = rest.dropFirst(digits.count)
    guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
    let title = after.dropFirst(2).replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    return title.isEmpty ? nil : (number, String(title.prefix(titleLimit)))
  }
}
