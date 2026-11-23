import Foundation

/// What fills a task's context window, under its meter (`ContextMeter`): the chat, the files and
/// pages it carried, memory, and the rest, which is the instructions and tools the AI app and
/// Serein send with every request. Serein counts the chat and the files itself (four characters
/// a token); the rest is known only when the harness reports the request's size, as what that
/// size leaves over. Memory shows on its own only when the host measured it, else it counts with
/// the instructions and the words say so. Pure: the meter's view draws `cells` and `parts`.
public struct ContextFill: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable { case instructions, memory, files, chat }
  public struct Part: Equatable, Sendable {
    public let kind: Kind
    public let tokens: Int
  }

  /// The model's window, in tokens.
  public let window: Int
  /// The parts that hold anything, in `Kind` order.
  public let parts: [Part]
  /// Memory was not measured on its own: it is inside the instructions part.
  public let memoryInInstructions: Bool
  /// The harness printed no request size: only Serein's own counts show, and `estimateNote` says
  /// what is missing.
  public let estimated: Bool

  /// The field's cells: each stands for an equal share of the window.
  public static let cellCount = 50
  public static let cellsPerRow = 25

  public init(window: Int, parts: [Part], memoryInInstructions: Bool, estimated: Bool) {
    self.window = window
    self.parts = parts
    self.memoryInInstructions = memoryInInstructions
    self.estimated = estimated
  }

  public var used: Int { parts.reduce(0) { $0 + $1.tokens } }
  public var left: Int { max(0, window - used) }

  /// `reported`: the request's size as the harness printed it, nil when it printed none;
  /// `chat` and `files`: Serein's own counts; `memory`: nil when not measured apart. Counts over
  /// the reported size are scaled down to fit it. Nil without a window or with nothing in it.
  public static func measure(window: Int?, reported: Int?, chat: Int, files: Int, memory: Int?) -> ContextFill? {
    guard let window, window > 0 else { return nil }
    var known: [(Kind, Int)] = [(.memory, max(0, memory ?? 0)), (.files, max(0, files)), (.chat, max(0, chat))]
    let counted = known.reduce(0) { $0 + $1.1 }
    var rest = 0
    if let total = reported, total > 0 {
      if counted > total {
        known = known.map { ($0.0, Int((Double($0.1) * Double(total) / Double(counted)).rounded(.down))) }
      } else {
        rest = total - counted
      }
    }
    let parts: [Part] = ([(Kind.instructions, rest)] + known).filter { $0.1 > 0 }.map { Part(kind: $0.0, tokens: $0.1) }
    guard !parts.isEmpty else { return nil }
    let given: Bool = (reported ?? 0) > 0
    return ContextFill(window: window, parts: parts, memoryInInstructions: memory == nil, estimated: !given)
  }

  public func words(_ kind: Kind) -> String {
    switch kind {
    case .instructions: return memoryInInstructions ? "Instructions, memory and tools" : "Instructions and tools"
    case .memory: return "Memory"
    case .files: return "Files and pages"
    case .chat: return "Chat"
    }
  }

  /// The part's share of the window, 1 to 100 for a part that holds anything.
  public func percent(_ part: Part) -> Int {
    min(100, max(1, Int((Double(part.tokens) * 100 / Double(window)).rounded())))
  }

  /// "Chat, about 41%, 82k tokens", as the list and a screen reader say it.
  public func line(_ part: Part) -> String {
    "\(words(part.kind)), about \(percent(part))%, \(Self.tokens(part.tokens)) tokens"
  }

  /// "About 28k tokens left."
  public var leftLine: String { "About \(Self.tokens(left)) tokens left." }

  /// Which part each cell shows, nil for a free one: a cell belongs to the part whose run of the
  /// window holds the cell's middle, so the field fills in `parts` order.
  public var cells: [Kind?] {
    (0..<Self.cellCount).map { index in
      let middle = (Double(index) + 0.5) / Double(Self.cellCount) * Double(window)
      var end = 0.0
      for part in parts {
        end += Double(part.tokens)
        if middle < end { return part.kind }
      }
      return nil
    }
  }

  /// "950", "28k", "1.2M".
  public static func tokens(_ count: Int) -> String {
    if count < 1_000 { return "\(max(0, count))" }
    if count < 1_000_000 { return "\(Int((Double(count) / 1_000).rounded()))k" }
    let millions = (Double(count) / 100_000).rounded() / 10
    return millions == millions.rounded() ? "\(Int(millions))M" : "\(millions)M"
  }

  /// Under an estimated field.
  public static let estimateNote = "This AI app reports no size, so its own instructions and tools are not counted."

  /// The one line beside Compact: what it does and that it can be undone.
  public static let compactNote = "Compact folds older replies into one summary. Your words and decisions stay, and Undo puts them back."
}
