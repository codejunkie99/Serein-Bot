import Foundation

/// The voice pill: hold the Ask Serein shortcut (or press Talk to Serein in the menu bar) and a
/// small pill floats at the foot of the screen, Serein's mark on top and the voice's wave along the
/// bottom; let go (or click the pill) and what was said goes to Serein as a message. Pure, so the
/// phases and what happens to the words are checked without a microphone or a window.
public struct VoicePill: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    /// Not on screen.
    case hidden
    /// On screen, the microphone still opening: the mark and a still wave.
    case waiting
    /// The microphone is open: the wave follows the voice.
    case listening
    /// Let go: the last words are being finished, then they go.
    case sending
  }
  /// Where Serein's reply shows once the words go.
  public enum Reply: Equatable, Sendable {
    /// Serein's chat is in front: the reply streams there.
    case chat
    /// Over another app: the bar opens and the reply grows under it.
    case bar
  }
  /// What happens to the words when the pill ends.
  public enum Handoff: Equatable, Sendable {
    case send(String, reply: Reply)
    /// Nothing was said, or the pill had already ended: nothing goes.
    case drop
  }

  /// Bars in the wave, oldest on the left.
  public static let barCount = 24
  /// Each new reading falls to this share of the one before when the voice drops, so the wave
  /// eases down instead of flickering between words.
  public static let decay: Float = 0.8

  public private(set) var phase: Phase = .hidden
  /// Always `barCount` long, each 0...1.
  public private(set) var levels = [Float](repeating: 0, count: VoicePill.barCount)
  /// The menu bar button started it: no key is held, so the pill takes a click to end.
  public private(set) var latched = false

  public init() {}

  public var shown: Bool { phase != .hidden }

  /// The hold began (or the button was pressed). A pill already up starts over.
  public mutating func begin(latched: Bool) {
    phase = .waiting
    levels = Self.still
    self.latched = latched
  }
  /// The microphone opened.
  public mutating func micOpened() {
    if phase == .waiting { phase = .listening }
  }
  /// A reading of the microphone, 0...1. It rises at once and eases down; outside listening it
  /// is ignored, so a reading that lands after the release never moves the wave.
  public mutating func hear(_ level: Float) {
    guard phase == .listening else { return }
    let reading = level.isFinite ? min(1, max(0, level)) : 0
    let next = max(reading, (levels.last ?? 0) * Self.decay)
    levels.removeFirst()
    levels.append(next)
  }
  /// Let go: the pill stays while the words are finished. Only a pill that is up can be let go.
  public mutating func release() {
    guard phase == .waiting || phase == .listening else { return }
    phase = .sending
    levels = Self.still
  }
  /// The words are finished: the pill goes, and they go to Serein unless nothing was said. Ends
  /// once: a second call, or one for a pill that never showed, drops.
  public mutating func end(heard: String, chatInFront: Bool) -> Handoff {
    let was = phase
    cancel()
    guard was != .hidden else { return .drop }
    let words = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return .drop }
    return .send(words, reply: chatInFront ? .chat : .bar)
  }
  /// The press was part of another shortcut, or Serein stopped: the pill goes, nothing is sent.
  public mutating func cancel() {
    phase = .hidden
    levels = Self.still
    latched = false
  }

  private static let still = [Float](repeating: 0, count: barCount)
}
