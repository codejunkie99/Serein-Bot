#if DEBUG
import AVFoundation
import Foundation
import SereinCore

/// Local speech only: no microphone, network, model or personal library access.
@MainActor enum CallSpeechChecks {
  private static func check(_ value: Bool, _ label: String) throws {
    guard value else { throw SereinError.invalid("FAIL: " + label) }
    print("PASS: " + label)
  }
  static func run() async throws {
    let sample = "So, is it safe yet? Not quite. That copy is **still in memory**.\n\nA flush asks the system to finish saving it."
    let passages = SpeechDelivery.callPassages(sample)
    try check(passages.count == 2 && passages[0].emphasis == "still in memory" && passages[1].emphasis == nil,
      "Calls preserve paragraph pauses and apply one existing emphasis phrase")
    let markup = SpeechDelivery.markup(passages)
    try check(markup.contains("<break time=\"350ms\"/>") && markup.contains("pitch=\"+3%\""),
      "Calls use the tested narration pacing and restrained expression")
    let voice = try SpeechDelivery.voice(for: sample)
    let words = SpeechDelivery.callUtterance(sample)!
    try check(words.voice?.identifier == voice.identifier && !voice.voiceTraits.contains(.isPersonalVoice),
      "Calls select the shared local voice without using a personal voice")
    if Locale.current.region?.identifier == "US", let ava = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Ava") {
      try check(words.voice?.identifier == ava.identifier, "Installed Ava Premium is selected for an English call")
      try check(SpeechDelivery.callUtterance("Allowed.")?.voice?.identifier == ava.identifier,
        "Short call confirmations keep Ava instead of guessing another language")
    }
    try check(SpeechDelivery.callUtterance("```swift\nprivateCode()\n``` ** **") == nil,
      "An empty or code-only reply starts no speech")
    let bounded = SpeechDelivery.callPassages(String(repeating: "word ", count: 300)).map(\.text).joined(separator: "\n\n")
    try check(bounded.count <= 800, "Calls retain the existing spoken-length bound")
    let quoted = SpeechDelivery.callPassages("Literal <voice name=\"other\"> & words.\n\n```text\nDO NOT READ CODE\n```")
    let escaped = SpeechDelivery.markup(quoted)
    try check(!escaped.contains("<voice ") && escaped.contains("&lt;voice") && escaped.contains("&amp;")
      && !escaped.contains("DO NOT READ CODE") && AVSpeechUtterance(ssmlRepresentation: escaped) != nil,
      "Call text cannot inject speech markup or read fenced code")
    for line in [CallVoice.allowed, CallVoice.declined, CallVoice.notAllowed,
      CallVoice.question(title: "Allow clicking this button", allowable: true),
      CallVoice.readBack(effect: .click, site: "example.com")] {
      try check(SpeechDelivery.callPassages(line).map(\.text).joined(separator: "\n\n") == line,
        "Call approval wording remains unchanged: " + line)
    }
    try check(CallVoice.reply(to: .yes, awaitingYes: false, allowable: true, enabled: true) != .answer(.yes)
      && CallVoice.reply(to: .allow, awaitingYes: false, allowable: true, enabled: true) == .readBack
      && CallVoice.reply(to: .yes, awaitingYes: true, allowable: true, enabled: true) == .answer(.yes),
      "Spoken allow still needs the existing read-back and second confirmation")
    try check(CallVoice.reply(to: .yes, awaitingYes: true, allowable: false, enabled: true) != .answer(.yes)
      && CallVoice.reply(to: .decline, awaitingYes: true, allowable: true, enabled: true) == .answer(.no),
      "A voice-ineligible action stays blocked and decline still works")

    let clip = try await StorySpeechWriter().write(words)
    try check(clip.seconds > 2 && clip.seconds < 30, "The exact call utterance renders measured audible speech")
    if let path = ProcessInfo.processInfo.environment["SEREIN_CALL_CAPTURES"] {
      let folder = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data(contentsOf: clip.file).write(to: folder.appendingPathComponent("call-preview.caf"))
      try JSONSerialization.data(withJSONObject: ["voice": voice.identifier, "quality": voice.quality.rawValue,
        "seconds": clip.seconds, "delivery": SpeechDelivery.version, "script": passages.map(\.text).joined(separator: "\n\n")], options: [.prettyPrinted, .sortedKeys])
        .write(to: folder.appendingPathComponent("call-preview.json"))
    }
    let probe = CallSpeechProbe()
    let synthesizer = AVSpeechSynthesizer(); synthesizer.delegate = probe
    let live = SpeechDelivery.callUtterance(sample)!
    probe.expected = live
    synthesizer.speak(live)
    for _ in 0..<300 where !probe.wordsStarted { try await Task.sleep(for: .milliseconds(10)) }
    try check(probe.started && probe.wordsStarted && probe.sameUtterance && probe.voice == voice.identifier,
      "The live speak API starts words with the selected voice and original utterance identity")
    let stopping = Date()
    let stopped = synthesizer.stopSpeaking(at: .immediate)
    // Some Apple voices report didFinish after a successful immediate stop. The controller
    // handles both terminal callbacks; test actual stopping and identity, not the event name.
    for _ in 0..<100 where !probe.cancelled && !probe.finished { try await Task.sleep(for: .milliseconds(10)) }
    try check(stopped && (probe.cancelled || probe.finished) && probe.endingIsExpected
      && !synthesizer.isSpeaking && Date().timeIntervalSince(stopping) < 1,
      "An interrupted call stops within a second and ends the original utterance")
  }
}

@MainActor private final class CallSpeechProbe: NSObject, AVSpeechSynthesizerDelegate {
  var started = false
  var cancelled = false
  var voice: String?
  var expected: AVSpeechUtterance?
  var sameUtterance = false
  var finished = false
  var wordsStarted = false
  var endingIsExpected = false
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let identifier = utterance.voice?.identifier
    Task { @MainActor in self.voice = identifier; self.sameUtterance = self.expected === utterance; self.started = true }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in self.cancelled = true; self.endingIsExpected = self.expected === utterance }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.finished = true; self.endingIsExpected = self.expected === utterance }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
    Task { @MainActor in self.wordsStarted = true }
  }
}
#endif
