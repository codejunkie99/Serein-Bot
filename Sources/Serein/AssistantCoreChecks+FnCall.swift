#if DEBUG
import Foundation
import SereinCore

/// Fn calling Serein from any app (FnCall.swift). Synthetic key states only.
extension AssistantCoreChecks {
  static func fnCall(_ check: Check) throws {
    /// Plays key states through a fresh machine and returns what it reported.
    func play(_ samples: [FnCallSample]) -> [FnCallEvent] {
      var machine = FnCallMachine()
      return samples.compactMap { machine.step($0) }
    }
    /// One sample. `key` is when another key last went down, on the same clock as `at`.
    func at(_ time: TimeInterval, fn: Bool, key: TimeInterval = -100, modifiers: Bool = false, claimed: Bool = false) -> FnCallSample {
      FnCallSample(fnDown: fn, otherModifiers: modifiers, claimed: claimed, secondsSinceKey: time - key, time: time)
    }

    try check(play([at(0, fn: true), at(0.1, fn: false)]) == [.tap], "A short press of Fn is a tap")
    try check(
      play([at(0, fn: true), at(0.1, fn: true), at(0.25, fn: true), at(1, fn: true), at(1.05, fn: false)]) == [.holdBegan, .holdEnded],
      "Holding Fn begins once, past the delay, and ends on release")
    try check(play([at(0, fn: true), at(0.1, fn: true)]).isEmpty, "Nothing happens before the hold delay")
    try check(play([at(0, fn: false), at(1, fn: false)]).isEmpty, "Nothing happens while Fn stays up")

    try check(play([at(0, fn: true), at(0.03, fn: true, key: 0.02), at(0.08, fn: false, key: 0.02)]).isEmpty,
      "Fn with a quick key is a shortcut, not a tap")
    try check(play([at(0, fn: true), at(0.5, fn: true, key: 0.4), at(0.6, fn: false, key: 0.4)]).isEmpty,
      "Fn with a key before the delay never opens anything")
    try check(
      play([at(0, fn: true), at(0.25, fn: true), at(1, fn: true, key: 0.9), at(1.1, fn: true, key: 0.9), at(1.2, fn: false, key: 0.9)])
        == [.holdBegan, .cancelled],
      "A key during a hold cancels it once, and the release sends nothing")
    try check(
      play([at(0, fn: true), at(0.25, fn: true), at(1, fn: false, key: 0.98)]) == [.holdBegan, .cancelled],
      "A key just before release still cancels")
    try check(play([at(0, fn: true, modifiers: true), at(0.3, fn: true, modifiers: true), at(0.4, fn: false)]).isEmpty,
      "Fn with Shift, Control, Option or Command does nothing")
    try check(
      play([at(0, fn: true), at(0.25, fn: true), at(0.5, fn: true, modifiers: true), at(0.6, fn: false)]) == [.holdBegan, .cancelled],
      "A modifier added during a hold cancels it")
    try check(play([at(0, fn: true, key: -0.02), at(0.3, fn: true, key: -0.02), at(0.4, fn: false, key: -0.02)]).isEmpty,
      "A key in the instant before the first sample counts as part of the press")
    try check(play([at(0, fn: true, key: -0.5), at(0.1, fn: false, key: -0.5)]) == [.tap],
      "Typing a moment earlier does not spoil a tap")

    try check(play([at(0, fn: true, claimed: true), at(0.3, fn: true, claimed: true), at(0.4, fn: false)]).isEmpty,
      "While dictation owns Fn, a press never calls Serein")
    try check(play([at(0, fn: true, claimed: true), at(0.3, fn: true), at(0.4, fn: false)]).isEmpty,
      "A press dictation owned stays ignored until it is let go")
    try check(
      play([at(0, fn: true, modifiers: true), at(0.1, fn: false), at(1, fn: true), at(1.1, fn: false)]) == [.tap],
      "The next press works after an ignored one")
  }
}
#endif
