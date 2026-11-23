import AppKit
import SereinCore
import SwiftUI

/// Process-local derived text, bounded by both entry count and an estimated byte cost.
/// Oversized answers are rendered normally without displacing the rest of the cache.
/// Only source strings and derived values are retained, never models or native views.
/// The cache never writes to disk.
@MainActor final class MessageRenderCache<Key: Hashable, Value> {
  private struct Entry {
    let value: Value
    let cost: Int
    var access: UInt64
  }
  private var entries: [Key: Entry] = [:]
  private var clock: UInt64 = 0
  private(set) var cost = 0
  var count: Int { entries.count }
  let costLimit: Int
  let entryLimit: Int

  init(costLimit: Int, entryLimit: Int = 128) {
    self.costLimit = max(0, costLimit)
    self.entryLimit = max(0, entryLimit)
  }

  func value(for key: Key, create: () -> (value: Value, cost: Int)) -> Value {
    clock &+= 1
    if var entry = entries[key] {
      entry.access = clock
      entries[key] = entry
      return entry.value
    }
    let result = create()
    let cost = max(0, result.cost)
    guard entryLimit > 0, cost <= costLimit else { return result.value }
    while entries.count >= entryLimit || self.cost > costLimit - cost {
      guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
      self.cost -= oldest.value.cost
      entries.removeValue(forKey: oldest.key)
    }
    entries[key] = Entry(value: result.value, cost: cost, access: clock)
    self.cost += cost
    return result.value
  }
}

@MainActor private enum MessageParseCaches {
  static let pieces = MessageRenderCache<String, [MessagePiece]>(costLimit: 2 * 1_024 * 1_024)
  static let blocks = MessageRenderCache<String, [MessageBlock]>(costLimit: 2 * 1_024 * 1_024)
  static let bubbles = MessageRenderCache<String, [ChatBubbles.Piece]>(costLimit: 2 * 1_024 * 1_024)
}

@MainActor func messageCachedPieces(_ source: String) -> [MessagePiece] {
  MessageParseCaches.pieces.value(for: source) {
    let value = messagePieces(source)
    return (value, source.utf8.count * 8 + value.count * 128)
  }
}

@MainActor func messageCachedBubbles(_ source: String) -> [ChatBubbles.Piece] {
  MessageParseCaches.bubbles.value(for: source) {
    let value = ChatBubbles.split(source)
    return (value, source.utf8.count * 2 + value.count * 128)
  }
}

@MainActor func messageCachedBlocks(_ source: String) -> [MessageBlock] {
  MessageParseCaches.blocks.value(for: source) {
    let value = messageBlocks(source)
    return (value, source.utf8.count * 8 + value.count * 128)
  }
}

struct MessageInlineStyleKey: Hashable {
  let source: String
  let size: CGFloat
  let weight: Font.Weight
  let color: Color
  let accent: Color
  let textScale: CGFloat
}

struct MessageCodeStyleKey: Hashable {
  let source: String
  let language: String?
  let light: Bool
}

@MainActor enum MessageStyledTextCaches {
  static let inline = MessageRenderCache<MessageInlineStyleKey, AttributedString>(costLimit: 4 * 1_024 * 1_024)
  static let code = MessageRenderCache<MessageCodeStyleKey, AttributedString>(costLimit: 4 * 1_024 * 1_024)
  static let regex = MessageRenderCache<String, NSRegularExpression>(costLimit: 64 * 1_024, entryLimit: 8)
}
