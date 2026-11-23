import Foundation

extension ReplyStory {
  /// A small visual vocabulary, not executable drawing instructions. Actions must describe
  /// the explanation itself; the host never invents a transfer, confirmation or number.
  public struct Visual: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
      case focus, gather, compare, search, result, transfer, hold, release, erase
    }
    public struct Figure: Codable, Equatable, Sendable {
      public var label: String
      public var value: Int
      public init(label: String, value: Int) { self.label = label; self.value = value }
    }
    public var kind: Kind
    public var from: Int?
    public var to: Int?
    public var headline: String?
    public var figures: [Figure]?
    public init(kind: Kind, from: Int? = nil, to: Int? = nil, headline: String? = nil, figures: [Figure]? = nil) {
      self.kind = kind; self.from = from; self.to = to; self.headline = headline; self.figures = figures
    }
    public func valid(nodeCount: Int) -> Bool {
      func words(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit && AgentPrivacy.redact(value) == value
      }
      if let from, !(0..<nodeCount).contains(from) { return false }
      if let to, !(0..<nodeCount).contains(to) { return false }
      if [.transfer, .hold, .release].contains(kind), from == nil || to == nil || from == to { return false }
      if let headline, !words(headline, limit: 64) { return false }
      if let figures {
        guard (1...3).contains(figures.count), Set(figures.map(\.label)).count == figures.count,
          figures.allSatisfy({ words($0.label, limit: 24) && (0...1_000_000).contains($0.value) }) else { return false }
      }
      return true
    }
  }
  public func visual(_ index: Int) -> Visual {
    // Older replies receive a new illustrated composition, but no inferred causal action.
    scenes[index].visual ?? .init(kind: .focus, headline: scenes[index].title)
  }
}
