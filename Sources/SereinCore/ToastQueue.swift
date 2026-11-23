import Foundation

/// The order and limits of the shared toast stack, without the views.
public struct ToastQueue<Item: Identifiable>: Sendable where Item: Sendable, Item.ID == String {
  public static var maxVisible: Int { 3 }
  public private(set) var items: [Item] = []
  public init() {}
  /// Adds a toast at the bottom (newest). A toast with the same id replaces the old one in place
  /// of stacking twice. Returns the ids pushed out because the stack was full.
  @discardableResult
  public mutating func push(_ item: Item) -> [String] {
    items.removeAll { $0.id == item.id }
    items.append(item)
    guard items.count > Self.maxVisible else { return [] }
    let out = items.prefix(items.count - Self.maxVisible).map(\.id)
    items.removeFirst(items.count - Self.maxVisible)
    return out
  }
  public mutating func remove(_ id: String) { items.removeAll { $0.id == id } }
  /// How long a toast stays. One with an action stays longer so it can be reached, and
  /// VoiceOver users get more time still.
  public static func duration(hasAction: Bool, voiceOver: Bool) -> TimeInterval {
    let base: TimeInterval = hasAction ? 8 : 4
    return voiceOver ? base * 2 : base
  }
}
