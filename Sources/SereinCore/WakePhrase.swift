import Foundation

/// Saying Serein's name to ask it something, hands-free (Settings › Voice › Say “Serein” to
/// ask). Only the words after the name are a request; whatever was heard before it is dropped.
public enum WakePhrase {
  /// Given to the recognizer as a hint, so it writes the name rather than a word that sounds like it.
  public static let name = "Serein"
  /// The ways the recognizer writes the name when it is said loosely (compared without case or
  /// accents). Sound-alikes count so the name works with any accent; common English words
  /// (“screen”, “siren”, “serenade”) and the name “Serena” do not, so ordinary talk stays quiet.
  public static let spellings: Set<String> = [
    "serein", "serene", "sereen", "serain", "sereine", "serine", "sirein", "sireen", "sirene",
    "sarain", "sarein", "cerein", "cerene", "sorein", "surein", "zerein", "zerene",
  ]
  /// The name heard as two words (“sir rain”), joined without the space.
  public static let splitSpellings: Set<String> = [
    "sirrain", "sirrein", "sirreign", "sirene", "serrain", "serain", "sarain", "sorain",
  ]
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
    let words = transcript.split(whereSeparator: \.isWhitespace).map(plain)
    let raw = transcript.split(whereSeparator: \.isWhitespace)
    var after: Int?
    for index in words.indices {
      if spellings.contains(words[index]) { after = index + 1; break }
      if index + 1 < words.count, splitSpellings.contains(words[index] + words[index + 1]) {
        after = index + 2
        break
      }
    }
    guard let after else { return nil }
    // “Serein, what's …”: a comma or dash after the name is not part of the request.
    let rest = raw[after...].drop(while: { $0.allSatisfy(\.isPunctuation) })
    return rest.joined(separator: " ")
  }

  static func plain(_ word: Substring) -> String {
    String(word).trimmingCharacters(in: .punctuationCharacters)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}
