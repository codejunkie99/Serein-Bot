import Foundation

/// What the ⌥Space bar does once a message has gone. A quick answer shows under the bar. Longer
/// work runs on with the bar out of the way, and one notification says when it ended; progress and
/// Stop are one ⌥Space away. Anything that waits on the person still interrupts (ApprovalPlacement).
public enum BarWork {
  /// How long the bar waits, and how often it looks again while words are arriving.
  public static let patience: TimeInterval = 5

  /// After each wait: whether the bar goes. Words still arriving keep it up, since someone is
  /// reading them; words that stopped mean the turn went off to work. It never goes while an answer
  /// is wanted or the person is writing or talking in it, or when no notification could reach them,
  /// because the answer would then vanish.
  public static func stepsAside(
    wordsBefore: Int, wordsNow: Int, working: Bool, waitsOnPerson: Bool, personBusy: Bool, canNotify: Bool
  ) -> Bool {
    working && !waitsOnPerson && !personBusy && canNotify && wordsNow <= wordsBefore
  }

  public enum Ending: Equatable, Sendable { case finished, failed, stopped }
  public struct Notice: Equatable, Sendable {
    public let title: String
    public let body: String
    public init(title: String, body: String) {
      self.title = title
      self.body = body
    }
  }
  public static let finished = "Finished."
  public static let failed = "Couldn't finish. Open the chat to see why."
  public static let bodyLimit = 160

  /// The one notification for a turn that ended with the bar away. A notification can show on a
  /// screen someone else sees, so a chat that read mail, messages or other personal data
  /// (`readPersonal`) gives no words of its reply. A turn the person stopped says nothing.
  public static func notice(name: String, ending: Ending, reply: String?, readPersonal: Bool) -> Notice? {
    switch ending {
    case .stopped: return nil
    case .failed: return Notice(title: name, body: failed)
    case .finished:
      let words = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !readPersonal, !words.isEmpty else { return Notice(title: name, body: finished) }
      guard words.count > bodyLimit else { return Notice(title: name, body: words) }
      let cut = words.prefix(bodyLimit - 1).trimmingCharacters(in: .whitespacesAndNewlines)
      return Notice(title: name, body: cut + "…")
    }
  }
}
