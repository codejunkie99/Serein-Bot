import Foundation

/// The filter on text kept for later prompts (memory notes, standing instructions, saved skills,
/// an assistant's job). What a page or file made the model write must not hide characters from the
/// person or tell a later turn to drop its rules. Pure; one list of each kind, here.
public enum SavedText {
  /// Invisible and direction-changing code points.
  static let hidden: [ClosedRange<UInt32>] = [
    0x200B...0x200F, 0x2028...0x2029, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF...0xFEFF,
    0xE0000...0xE007F,
  ]
  /// Steering phrases, lowercase, single-spaced.
  public static let phrases: [String] = [
    "ignore previous instructions", "ignore all previous instructions", "ignore the above", "ignore your instructions",
    "disregard the above", "disregard previous instructions", "disregard your instructions", "you are now",
    "system prompt", "new instructions", "forget your instructions", "override your instructions",
  ]

  /// One plain sentence saying why `text` cannot be saved, or nil when it can.
  public static func problem(_ text: String) -> String? {
    let scalars = Array(text.unicodeScalars)
    for (i, s) in scalars.enumerated() where hidden.contains(where: { $0.contains(s.value) }) {
      if joiner(scalars, i) { continue }
      return "That text has hidden or direction-changing characters, so it was not saved."
    }
    let flat = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if phrases.contains(where: { flat.contains($0) }) {
      return "That text reads like an instruction to the assistant rather than a note, so it was not saved."
    }
    return nil
  }

  /// A zero-width (non-)joiner that ordinary text needs: between two emoji (family, flags of
  /// people) or two non-ASCII letters (Persian, Hindi). Anywhere else it hides something.
  private static func joiner(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
    guard s[i].value == 0x200D || s[i].value == 0x200C, i > 0, i + 1 < s.count else { return false }
    let a = s[i - 1], b = s[i + 1]
    func emoji(_ x: Unicode.Scalar) -> Bool { x.value > 0xFF && x.properties.isEmoji || x.value == 0xFE0F }
    func letter(_ x: Unicode.Scalar) -> Bool { x.value > 0x7F && x.properties.isAlphabetic }
    return s[i].value == 0x200D && emoji(a) && emoji(b) || letter(a) && letter(b)
  }
}
