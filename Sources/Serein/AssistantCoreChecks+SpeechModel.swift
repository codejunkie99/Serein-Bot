#if DEBUG
import Foundation
import SereinCore

/// Which speech model file dictation may use (SpeechModel.swift). No file is read.
extension AssistantCoreChecks {
  static func speechModel(_ check: Check) throws {
    let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")
    let own = support.appendingPathComponent("Serein/Models/" + SpeechModel.fileName)
    let hex = support.appendingPathComponent("hex/models/" + SpeechModel.fileName)
    func found(_ sizes: [URL: Int64]) -> URL? {
      SpeechModel.found(applicationSupport: support) { sizes[$0] }
    }
    try check(found([:]) == nil, "No model file means Apple Speech")
    try check(found([hex: SpeechModel.bytes]) == hex, "The file Hex already fetched is used where it is")
    try check(found([own: SpeechModel.bytes, hex: SpeechModel.bytes]) == own, "Serein's own copy comes first")
    try check(found([own: 1_024, hex: SpeechModel.bytes]) == hex, "A part-written copy is passed over")
    try check(found([own: 1_024, hex: SpeechModel.bytes + 1]) == nil, "A file of another length is not the model")
    try check(SpeechModel.hears("en-US") && SpeechModel.hears("en_GB") && SpeechModel.hears("en"),
      "The model takes every English locale")
    try check(!SpeechModel.hears("fr-FR") && !SpeechModel.hears("de") && !SpeechModel.hears(""),
      "Other languages stay on Apple Speech")
    try check(
      SpeechModel.source.host == "huggingface.co" && SpeechModel.source.lastPathComponent == SpeechModel.fileName
        && SpeechModel.source.path.contains("/resolve/7e948f21b7bdbac698d3318db9d350f1096f3b6c/")
        && SpeechModel.sha256.count == 64,
      "The download is pinned to one revision and one checksum")
    let heard = SpeechModel.segments(pieces: [
      (" late", 0.99), (" chan", 0.97), ("ge", 0.41), ("?", 0.2), (" Pri", 0.9), ("ya", 0.95), (".", 0.99),
    ])
    try check(heard.map(\.text) == ["late", "change?", "Priya."],
      "A piece that starts with a space starts a word, and punctuation stays on its word")
    try check(heard[0].confidence > 0.98 && abs(heard[1].confidence - 0.41) < 0.001 && heard[2].confidence > 0.89,
      "A word is as sure as its least sure piece, and an unsure question mark does not count")
    try check(TalkProofread.lowSegments(heard) == ["change?"], "Only the unsure word goes to proofreading")
    try check(SpeechModel.segments(pieces: []).isEmpty && SpeechModel.segments(pieces: [(" ", 0.5)]).isEmpty,
      "No pieces, or only a space, is no word")
    try check(
      SpeechModel.window.left % 80 == 0 && SpeechModel.window.chunk % 80 == 0 && SpeechModel.window.right % 80 == 0
        && SpeechModel.feedSamples * 1_000 / SpeechModel.sampleRate == 160,
      "The model's window is in whole 80 ms steps and sound is fed 160 ms at a time")
    func follows(_ address: String) -> Bool { URL(string: address).map(SpeechModel.mayFollow) == true }
    try check(
      follows("https://us.aws.cdn.hf.co/repos/x") && follows("https://huggingface.co/x") && follows("https://cdn-lfs.huggingface.co/x")
        && !follows("http://us.aws.cdn.hf.co/x") && !follows("https://hf.co.example.com/x") && !follows("https://nothf.co/x")
        && !follows("https://example.com/huggingface.co") && !follows("file:///tmp/x"),
      "The download follows a redirect only to Hugging Face's own hosts, over HTTPS")
    func offers(supported: Bool = true, there: Bool = false, declined: Bool = false, cardWaiting: Bool = false) -> Bool {
      SereinSetup.offersSpeech(supported: supported, there: there, declined: declined, cardWaiting: cardWaiting)
    }
    try check(
      offers() && !offers(supported: false) && !offers(there: true) && !offers(declined: true) && !offers(cardWaiting: true)
        && (try? SereinSetup.topic(["topic": "speech"])) == .speech,
      "The speech model is offered on a Mac that can run it and lacks it, once, and never over another card")
  }
}
#endif
