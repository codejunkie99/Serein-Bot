import Foundation

/// What holding or tapping Fn means for calling Serein from any app.
public enum FnCallEvent: Equatable { case tap, holdBegan, holdEnded, cancelled }

/// One reading of the keyboard. It holds only whether keys are down and how long ago a key was
/// pressed, never which key: Serein does not read what is typed in other apps.
public struct FnCallSample: Equatable {
  public var fnDown: Bool
  /// Shift, Control, Option or Command is down too.
  public var otherModifiers: Bool
  /// Something else owns this press (dictation while Serein is in front).
  public var claimed: Bool
  public var secondsSinceKey: Double
  public var time: TimeInterval
  public init(fnDown: Bool, otherModifiers: Bool, claimed: Bool, secondsSinceKey: Double, time: TimeInterval) {
    self.fnDown = fnDown
    self.otherModifiers = otherModifiers
    self.claimed = claimed
    self.secondsSinceKey = secondsSinceKey
    self.time = time
  }
}

/// Turns readings of the keyboard into tap, hold, release and cancel. Fn is also half of many
/// shortcuts (Fn and an arrow, Fn and a function key), so it waits before it means anything and
/// any other key makes the whole press count for nothing. Pure, so it is checked without a keyboard.
public struct FnCallMachine {
  public static let sampleInterval: TimeInterval = 0.05
  /// How long Fn stays down alone before it counts as a hold.
  public static let holdDelay: TimeInterval = 0.2
  /// A key this close before the first reading is part of the press: readings are a moment apart.
  static let keySlack: TimeInterval = 0.06

  private enum State: Equatable {
    case idle, ignored
    case pressed(since: TimeInterval), holding(since: TimeInterval)
  }
  private var state = State.idle
  public init() {}

  public mutating func step(_ sample: FnCallSample) -> FnCallEvent? {
    switch state {
    case .idle:
      guard sample.fnDown else { return nil }
      state = sample.claimed || Self.isChord(sample, since: sample.time) ? .ignored : .pressed(since: sample.time)
      return nil
    case .ignored:
      if !sample.fnDown { state = .idle }
      return nil
    case .pressed(let since):
      if Self.isChord(sample, since: since) {
        state = sample.fnDown ? .ignored : .idle
        return nil
      }
      guard sample.fnDown else {
        state = .idle
        return .tap
      }
      guard sample.time - since >= Self.holdDelay else { return nil }
      state = .holding(since: since)
      return .holdBegan
    case .holding(let since):
      if Self.isChord(sample, since: since) {
        state = sample.fnDown ? .ignored : .idle
        return .cancelled
      }
      guard !sample.fnDown else { return nil }
      state = .idle
      return .holdEnded
    }
  }

  private static func isChord(_ sample: FnCallSample, since: TimeInterval) -> Bool {
    sample.otherModifiers || sample.secondsSinceKey < sample.time - since + keySlack
  }
}
