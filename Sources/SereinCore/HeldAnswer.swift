import Foundation

/// Answers to an edit approval given while that task's thread is still working. The buttons are
/// never disabled: an answer given mid-step is held, a later answer for the same thread replaces
/// it, and when the thread's step ends it is applied into that thread (wherever the user is by
/// then). Stopping the step discards it, since the user stopped what it would have continued.
public struct HeldAnswers<Resolution: Equatable & Sendable>: Equatable, Sendable {
  public struct Answer: Equatable, Sendable {
    public var reviewID: String
    public var threadID: String
    public var resolution: Resolution
    /// The words a Decline sends with it.
    public var reply: String
    public init(reviewID: String, threadID: String, resolution: Resolution, reply: String = "") {
      self.reviewID = reviewID
      self.threadID = threadID
      self.resolution = resolution
      self.reply = reply
    }
  }
  public enum Placement: Equatable, Sendable {
    /// The thread is idle: apply the answer now.
    case now
    /// The thread works: the answer waits for its step to end.
    case held
  }
  /// One answer per thread: the latest.
  public private(set) var byThread: [String: Answer] = [:]
  public init() {}

  /// Records `answer`: held when its thread is working, else to be applied now (and nothing is
  /// kept). Either way it replaces an earlier held answer for that thread.
  public mutating func answer(_ answer: Answer, threadWorking: Bool) -> Placement {
    guard threadWorking else {
      byThread[answer.threadID] = nil
      return .now
    }
    byThread[answer.threadID] = answer
    return .held
  }
  /// The held answer shown on a review's card.
  public func held(reviewID: String) -> Answer? {
    byThread.values.first { $0.reviewID == reviewID }
  }
  public func isHolding(thread: String) -> Bool { byThread[thread] != nil }
  /// The thread's step ended: the answer to apply now, or nil (none held, or the step was
  /// stopped, which discards it).
  public mutating func stepEnded(thread: String, stopped: Bool) -> Answer? {
    guard let answer = byThread.removeValue(forKey: thread) else { return nil }
    return stopped ? nil : answer
  }
  /// Forgets the thread's held answer (the thread was deleted).
  public mutating func discard(thread: String) {
    byThread[thread] = nil
  }
}
