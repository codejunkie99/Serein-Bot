import Foundation

/// Saying Serein's name to ask it something, hands-free (Settings › Voice › Say “Serein” to
/// ask). Only the words after the name are a request; whatever was heard before it is dropped.
public enum WakePhrase {
  /// Given to the recognizer as a hint, so it writes the name rather than a word that sounds like it.
  public static let name = "Serein"
  /// The name as the recognizer writes it with `name` as its hint (compared without case or
  /// accents). Sound-alike words (“serene”) are not accepted: page audio or talk in the room
  /// would become a request.
  public static let spellings: Set<String> = ["serein"]
  /// The request goes once nothing new has been heard for this long.
  public static let silence: TimeInterval = 2
  /// Nothing after the name for this long: nothing is sent and the bar goes again.
  public static let nothingSaid: TimeInterval = 6
  /// A request is sent after this long, however much is still being said.
  public static let limit: TimeInterval = 30
  /// Waiting for the name, a recognition starts afresh this often: Apple ends one after about a
  /// minute, and a request that follows the name may take `limit` more.
  public static let restart: TimeInterval = 25

  /// The words after the first time the name is said in `transcript`, or nil when it was not
  /// said. An empty string: the name alone, so far.
  public static func request(in transcript: String) -> String? {
    let words = transcript.split(whereSeparator: \.isWhitespace)
    guard let index = words.firstIndex(where: isName) else { return nil }
    // “Serein, what's …”: a comma or dash after the name is not part of the request.
    let rest = words[(index + 1)...].drop(while: { $0.allSatisfy(\.isPunctuation) })
    return rest.joined(separator: " ")
  }

  static func isName(_ word: Substring) -> Bool {
    let plain = String(word).trimmingCharacters(in: .punctuationCharacters)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    return spellings.contains(plain)
  }
}
