import Foundation

/// The voice pill: a tiny pill rests at the foot of the screen; hold the Ask Serein shortcut (or
/// click the pill, or press Talk to Serein in the menu bar) and it grows into a small capsule
/// holding Serein's mark, whose orbits spin and swell with the voice; let go (or click it) and it
/// shrinks back while
/// what was said goes to Serein, whose chat comes forward with the message in it. Pure, so the
/// phases and what happens to the words are checked without a microphone or a window.
public struct VoicePill: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    /// At rest: the tiny pill, or nothing.
    case hidden
    /// Grown, the microphone still opening: the mark holds still.
    case waiting
    /// The microphone is open: the mark spins and swells with the voice.
    case listening
    /// Let go: the last words are being finished, then they go.
    case sending
  }
  /// What happens to the words when the pill ends.
  public enum Handoff: Equatable, Sendable {
    /// They go to Serein, and Serein's chat comes forward showing them.
    case send(String)
    /// Nothing was said, or the pill had already ended: nothing goes.
    case drop
  }

  /// When the voice drops, the swell falls to this share of itself each reading, so the mark eases
  /// down instead of flickering between words.
  public static let decay: Float = 0.8
  /// Degrees the orbits turn each reading (about 47 a second) while listening in silence, and
  /// the extra a full voice adds: the louder, the faster.
  public static let quietTurn = 0.6
  public static let voiceTurn = 7.0

  public private(set) var phase: Phase = .hidden
  /// How much the mark swells, 0...1.
  public private(set) var level: Float = 0
  /// How far the orbits have turned, in degrees. Only grows, so the spin never runs backwards.
  public private(set) var turn = 0.0
  /// The menu bar button started it: no key is held, so the pill takes a click to end.
  public private(set) var latched = false

  public init() {}

  public var shown: Bool { phase != .hidden }

  /// The hold began (or the button was pressed). A pill already up starts over.
  public mutating func begin(latched: Bool) {
    phase = .waiting
    level = 0
    turn = 0
    self.latched = latched
  }
  /// The microphone opened.
  public mutating func micOpened() {
    if phase == .waiting { phase = .listening }
  }
  /// A reading of the microphone, 0...1. The swell rises at once and eases down, and the orbits
  /// turn by it; outside listening it is ignored, so a reading after the release moves nothing.
  public mutating func hear(_ reading: Float) {
    guard phase == .listening else { return }
    let reading = reading.isFinite ? min(1, max(0, reading)) : 0
    level = max(reading, level * Self.decay)
    turn += Self.quietTurn + Double(level) * Self.voiceTurn
  }
  /// Let go: the pill stays while the words are finished. Only a pill that is up can be let go.
  public mutating func release() {
    guard phase == .waiting || phase == .listening else { return }
    phase = .sending
    level = 0
  }
  /// The words are finished: the pill goes back to rest, and they go to Serein unless nothing was
  /// said. Ends once: a second call, or one for a pill that never grew, drops.
  public mutating func end(heard: String) -> Handoff {
    let was = phase
    cancel()
    guard was != .hidden else { return .drop }
    let words = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return .drop }
    return .send(words)
  }
  /// The press was part of another shortcut, the microphone could not open, or Serein stopped: the
  /// pill goes back to rest and nothing is sent.
  public mutating func cancel() {
    phase = .hidden
    level = 0
    latched = false
  }
}
