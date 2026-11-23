import Foundation

/// The replies to one question in a chat: Try again keeps the reply it replaces, so the person
/// can step back to it ("1 of 2"). Kept in memory for this launch, one question per chat: the
/// newest, the only reply Try again is offered on.
public struct ReplyVersions: Equatable, Sendable {
  /// The person's words these replies answer. Try again rewinds and sends them again, so the
  /// message is new but its words are the same.
  public var asked: String
  /// The replies Try again replaced, oldest first.
  public var earlier: [String] = []
  /// The version on screen, from 0; nil shows the newest.
  public var shown: Int?
  /// At most this many earlier versions; the oldest goes first.
  public static let limit = 9
  public init(asked: String) { self.asked = asked }

  /// Try again on `chat`'s newest reply: it joins the earlier versions of its question, and the
  /// reply to come shows. A different question in that chat starts over.
  public static func keep(_ reply: String, asked: String, chat: String, in book: inout [String: ReplyVersions]) {
    var versions = book[chat].flatMap { $0.asked == asked ? $0 : nil } ?? ReplyVersions(asked: asked)
    if versions.earlier.last != reply { versions.earlier.append(reply) }
    if versions.earlier.count > limit { versions.earlier.removeFirst(versions.earlier.count - limit) }
    versions.shown = nil
    book[chat] = versions
  }
  /// The versions of the reply to `asked` in `chat`, when Try again kept any.
  public static func of(chat: String, asked: String, in book: [String: ReplyVersions]) -> ReplyVersions? {
    guard let versions = book[chat], versions.asked == asked, !versions.earlier.isEmpty else { return nil }
    return versions
  }

  public var count: Int { earlier.count + 1 }
  /// The version on screen, from 0.
  public var index: Int { min(shown ?? earlier.count, earlier.count) }
  /// The words of the version on screen; `current` is the newest reply.
  public func text(current: String) -> String { index < earlier.count ? earlier[index] : current }
  /// One step back (-1) or on (+1), held at either end.
  public mutating func step(_ by: Int) {
    let next = max(0, min(earlier.count, index + by))
    shown = next == earlier.count ? nil : next
  }
  /// "1 of 2", counted from 1.
  public var position: String { "\(index + 1) of \(count)" }
}
