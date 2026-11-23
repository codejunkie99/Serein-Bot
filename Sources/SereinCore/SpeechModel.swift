import Foundation

/// The speech model dictation runs on when its file is on this Mac: NVIDIA Parakeet Unified
/// English 0.6B as an 8-bit GGUF, run by transcribe.cpp on Metal (the model and engine Hex uses).
/// It hears English only; every other language, and a Mac without the file, stays on Apple Speech.
public enum SpeechModel {
  public static let fileName = "parakeet-unified-en-0.6b-Q8_0.gguf"
  public static let bytes: Int64 = 731_357_568
  public static let sha256 = "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"
  /// Pinned to a revision, so the checksum above is the only file this address can give.
  public static let source = URL(
    string: "https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/resolve/7e948f21b7bdbac698d3318db9d350f1096f3b6c/"
      + fileName)!
  /// What the model wants: mono, 32-bit float.
  public static let sampleRate = 16_000
  /// How much sound the model keeps behind, takes at once and waits for ahead, in milliseconds;
  /// one of the settings it was trained on. Measured on an M5 with a 15 s recording: text 120 ms
  /// after the key is let go and first words after 1.8 s. The widest (1040, 1040) is as accurate
  /// and shows words a second later; the narrow ones (160, 320) show words sooner, finish in
  /// 210 ms and keep the graphics chip a third busy.
  public static let window = (left: 5_600, chunk: 560, right: 560)
  /// Sound goes to the model in pieces of this many samples (160 ms).
  public static let feedSamples = 2_560

  /// Serein's own copy first, then the same file where Hex keeps it.
  public static func candidates(applicationSupport: URL) -> [URL] {
    ["Serein/Models", "hex/models"].map {
      applicationSupport.appendingPathComponent($0).appendingPathComponent(fileName)
    }
  }

  /// The first candidate that is the whole file. `size` reads a file's length, nil when it is not there.
  // shortcut: a found file is trusted by its exact length; hash it against `sha256` if a file
  // from anywhere but Serein's own checked download or Hex's checked one is ever accepted.
  public static func found(applicationSupport: URL, size: (URL) -> Int64?) -> URL? {
    candidates(applicationSupport: applicationSupport).first { size($0) == bytes }
  }

  /// The model's pieces as words: a piece that starts with a space starts a word. A word is as
  /// sure as its least sure piece; punctuation joins its word without a say, so an unsure comma
  /// never sends a dictation to proofreading.
  public static func segments(pieces: [(text: String, sure: Float)]) -> [TalkSegment] {
    var words: [TalkSegment] = []
    for piece in pieces {
      let spoken = piece.text.contains { $0.isLetter || $0.isNumber }
      let sure = spoken ? Double(max(0, min(1, piece.sure))) : 1
      if piece.text.hasPrefix(" ") || words.isEmpty {
        words.append(TalkSegment(text: piece.text.trimmingCharacters(in: .whitespaces), confidence: sure))
      } else {
        words[words.count - 1].text += piece.text
        words[words.count - 1].confidence = min(words[words.count - 1].confidence, sure)
      }
    }
    return words.filter { !$0.text.isEmpty }
  }

  /// Hugging Face answers the pinned address with a redirect to one of its own file hosts
  /// (measured: `us.aws.cdn.hf.co`). Only its hosts are followed, over HTTPS; the checksum decides
  /// what is kept either way.
  public static func mayFollow(_ url: URL) -> Bool {
    guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
    return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
  }

  public static func hears(_ locale: String) -> Bool {
    TalkLanguage.canonical(locale).lowercased().split(separator: "-").first == "en"
  }
}
