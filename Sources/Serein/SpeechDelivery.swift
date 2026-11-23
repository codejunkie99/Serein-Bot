import AVFoundation
import Foundation
import NaturalLanguage
import SereinCore

/// One local voice and delivery policy for calls, read-aloud replies and story narration.
/// Agent text is always escaped; only the host owns the small, tested SSML vocabulary.
enum SpeechDelivery {
  static let rate: Float = 0.47
  static let version = "conversation-v1"
  static let callGuidance = """
    This reply will be spoken in a voice call. Explain it to one listener in short, varied sentences, with familiar words and natural contractions. Use a question only when it helps the explanation; avoid stage directions, fake laughter and forced enthusiasm. Put the answer and its essential conditions or caveats first. Keep the reply within 800 characters when possible; offer more detail instead of reading a long report. Do not read headings, markup or URLs aloud. Prefer plain spoken text unless the person asks for a visual or another format. Voice delivery changes no permissions or approval rules.
    """
  struct Passage {
    let text: String
    var emphasis: String? = nil
  }

  static func voice(for text: String) throws -> AVSpeechSynthesisVoice {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    let detected = (text.count >= 20 ? recognizer.dominantLanguage?.rawValue : nil)
      ?? Locale.current.language.languageCode?.identifier ?? "en"
    let language = String(detected.split(separator: "-").first ?? "en")
    let voices = AVSpeechSynthesisVoice.speechVoices().filter {
      $0.language.split(separator: "-").first.map(String.init) == language
        && !$0.voiceTraits.contains(.isPersonalVoice)
        && ($0.identifier.hasPrefix("com.apple.voice.") || $0.identifier.hasPrefix("com.apple.ttsbundle.siri_"))
    }
    func score(_ voice: AVSpeechSynthesisVoice) -> Int {
      Int(voice.quality.rawValue) * 100
        + (voice.language == language + "-" + (Locale.current.region?.identifier ?? "US") ? 10 : 0)
        + (voice.identifier.contains("siri_") ? 5 : 0)
        + (voice.identifier.contains("siri_nicky_") ? 1 : 0)
        + (voice.identifier == "com.apple.voice.premium.en-US.Ava" ? 6 : 0)
    }
    guard let voice = voices.sorted(by: {
      score($0) == score($1) ? $0.identifier < $1.identifier : score($0) > score($1)
    }).first else {
      throw SereinError.invalid("No local voice is installed for this language. Add one in macOS Spoken Content, then try again.")
    }
    return voice
  }

  static func markup(_ passages: [Passage]) -> String {
    func escaped(_ text: String) -> String {
      text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    let parts = passages.map { passage in
      guard let phrase = passage.emphasis, !phrase.isEmpty, phrase.count <= 60,
        let range = passage.text.range(of: phrase) else { return escaped(passage.text) }
      // Apple's emphasis tag crashes TextToSpeech on macOS 15. This tested prosody subset
      // gives the phrase a small slowdown and pitch lift without changing its words.
      return escaped(String(passage.text[..<range.lowerBound])) + "<prosody rate=\"92%\" pitch=\"+3%\">"
        + escaped(phrase) + "</prosody>" + escaped(String(passage.text[range.upperBound...]))
    }
    return "<speak><prosody rate=\"97%\">" + parts.joined(separator: "<break time=\"350ms\"/>") + "</prosody></speak>"
  }

  static func utterance(_ passages: [Passage], voice: AVSpeechSynthesisVoice?) -> AVSpeechUtterance {
    let words: AVSpeechUtterance
    if let expressive = AVSpeechUtterance(ssmlRepresentation: markup(passages)) {
      words = expressive
    } else {
      words = AVSpeechUtterance(string: passages.map(\.text).joined(separator: "\n\n")); words.rate = rate
    }
    words.voice = voice
    return words
  }

  static func callPassages(_ text: String) -> [Passage] {
    // Keep the existing call bound and code/Markdown exclusions. Optional bold emphasis uses
    // only words already in the reply; approval questions and read-backs stay verbatim.
    let withoutCode = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
    let phrase = withoutCode.range(of: #"\*\*([^*\n]{1,60})\*\*"#, options: .regularExpression)
      .map { String(withoutCode[$0].dropFirst(2).dropLast(2)) }
    let plain = String(withoutCode.replacingOccurrences(of: "[*_`#>\\[\\]]", with: "", options: .regularExpression).prefix(800))
    var remainingEmphasis = phrase
    return plain.components(separatedBy: "\n\n").compactMap { paragraph in
      let words = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !words.isEmpty else { return nil }
      let emphasis = remainingEmphasis.flatMap { words.contains($0) ? $0 : nil }
      if emphasis != nil { remainingEmphasis = nil }
      return Passage(text: words, emphasis: emphasis)
    }
  }

  static func callUtterance(_ text: String) -> AVSpeechUtterance? {
    let passages = callPassages(text)
    guard !passages.isEmpty else { return nil }
    let words = passages.map(\.text).joined(separator: "\n\n")
    return utterance(passages, voice: try? voice(for: words))
  }
}
