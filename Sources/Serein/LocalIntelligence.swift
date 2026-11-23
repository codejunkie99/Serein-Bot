import AVFoundation
import Foundation
import NaturalLanguage
import SereinCore
import Speech
import SwiftUI

@MainActor final class LocalRecall: ObservableObject {
  @Published var matches: [Visit] = []
  @Published var searching = false
  @Published var message: String?
  private var searchTask: Task<Void, Never>?
  private var observer: NSObjectProtocol?
  init() {
    observer = NotificationCenter.default.addObserver(
      forName: .sereinHistoryCleared, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.searchTask?.cancel()
        self?.matches = []
        self?.searching = false
      }
    }
  }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  func search(_ query: String, visits: [Visit], library: URL) {
    searchTask?.cancel()
    searching = true
    message = nil
    searchTask = Task {
      let worker = Task.detached(priority: .utility) {
        try await SemanticSearchService.shared.search(
          query: query, visits: visits, library: library)
      }
      do {
        let ids = try await withTaskCancellationHandler(
          operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        let byID = Dictionary(visits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        matches = ids.compactMap { byID[$0] }
        message = "On-device index · \(visits.count) saved visits · embeddings cached on disk"
      } catch {
        guard !Task.isCancelled else { return }
        message = error.localizedDescription
        matches = []
      }
      searching = false
    }
  }
}
/// The live input level. It changes with every block of microphone audio, so it is kept out of
/// Dictation's published state: a view that shows only the mic button never redraws at that rate.
@MainActor final class DictationMeter: ObservableObject {
  @Published var level: Float = 0
}
@MainActor final class Dictation: ObservableObject {
  @Published var recording = false
  @Published var error: String?
  /// From a start until the microphone opens (permission, recognizer and engine): a mic button
  /// shows that the click was taken.
  @Published private(set) var starting = false
  /// Why the last dictation stopped on its own, when that was not an error.
  @Published private(set) var endNote: String?
  /// A new engine for each dictation: an engine kept from before can hold the format of a
  /// microphone that is gone, and a tap in that format stops the app.
  private var engine = AVAudioEngine()
  /// The microphone's way to the current recognition: a new recognition takes over without
  /// closing the microphone.
  private let feed = RecognitionFeed()
  private var recognizer: SFSpeechRecognizer?
  private var onText: ((String) -> Void)?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var hasTap = false
  private var timeout: Task<Void, Never>?
  private var inputWatch: NSObjectProtocol?
  /// Input device changes in this dictation: a microphone that keeps changing stops it.
  private var inputChanges = 0
  /// Bumped by every recognition and every stop: a result or timer from an older one is ignored.
  private var generation = 0
  /// What the recognitions that ended while the microphone stayed open heard. The on-device
  /// recognizer ends a recognition at a pause; the next one continues from these words.
  private var committed = ""
  private var committedSegments: [TalkSegment] = []
  private var recognitionStartedAt = Date.distantPast
  /// This dictation's place in the speech engine, when the model has it; nil on Apple Speech.
  private var speech: Int?
  // Push-to-talk support: live level, per-segment confidence, optional recording, and a finish() that waits.
  let meter = DictationMeter()
  var level: Float {
    get { meter.level }
    set { meter.level = newValue }
  }
  private(set) var segments: [TalkSegment] = []
  private(set) var latest = ""
  var recordTo: URL?
  /// The locale identifier of the current or last recognition.
  private(set) var language: String?
  private(set) var audio = PendingTalkAudio()
  private var finalWaiter: CheckedContinuation<Void, Never>?
  /// Bumped by every stop, so a start still waiting on permission never opens the mic later.
  private var startToken = 0
  /// Dictations started and not yet stopped, anywhere in Serein (push to talk, ⌥Space held, a
  /// call, the guided setup): the wake phrase keeps off the microphone meanwhile (WakeListener).
  private(set) static var claimed = 0
  static let claimsChanged = Notification.Name("serein.dictation.claimsChanged")
  private var claiming = false {
    didSet {
      guard claiming != oldValue else { return }
      // A start that let go of its claim before the microphone opened has ended.
      if !claiming, starting { starting = false }
      Self.claimed += claiming ? 1 : -1
      NotificationCenter.default.post(name: Self.claimsChanged, object: nil)
    }
  }
  func start(onText: @escaping (String) -> Void) {
    guard !recording else {
      stop()
      return
    }
    // Claimed before permission is asked, so the wake phrase lets go of the microphone first.
    claiming = true
    starting = true
    endNote = nil
    // A start that never reaches `begin` (a quick release, no permission, no recognizer) must not
    // hand the previous recognition's words to `finish`.
    latest = ""
    segments = []
    error = nil
    startToken += 1
    let token = startToken
    SFSpeechRecognizer.requestAuthorization { status in
      Task { @MainActor in
        guard token == self.startToken else { return }
        guard status == .authorized else {
          self.error = "Enable Speech Recognition for Serein in System Settings."
          self.claiming = false
          return
        }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard token == self.startToken else { return }
        guard allowed else {
          self.error = "Enable microphone access for Serein in System Settings."
          self.claiming = false
          return
        }
        self.begin(onText: onText)
      }
    }
  }
  private func begin(onText: @escaping (String) -> Void) {
    guard let id = TalkLanguageSupport.resolved(),
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)),
      recognizer.supportsOnDeviceRecognition
    else {
      error = "On-device recognition is unavailable for this language on this Mac."
      claiming = false
      return
    }
    stop()
    // `stop` let go of the claim; this dictation still holds it.
    claiming = true
    language = id
    segments = []
    latest = ""
    committed = ""
    committedSegments = []
    inputChanges = 0
    self.recognizer = recognizer
    self.onText = onText
    audio = PendingTalkAudio()
    // The speech model when it is loaded, free and hears this language; Apple Speech otherwise.
    if SpeechModel.hears(id) {
      generation += 1
      let current = generation
      speech = SpeechEngine.shared.begin { [weak self] text in
        Task { @MainActor in
          guard let self, current == self.generation, self.recording else { return }
          self.latest = Self.joined(self.committed, text)
          onText(self.latest)
        }
      }
    }
    guard openMicrophone() else { return }
    if speech == nil { recognize() }
    timeout = Task {
      try? await Task.sleep(nanoseconds: 60_000_000_000)
      guard !Task.isCancelled else { return }
      // The model's words trail the voice by a second: it is asked for the rest before stopping.
      if speech != nil { _ = await finish() } else { stop() }
      endNote = "Stopped after a minute. The words so far are kept."
    }
  }
  /// A new engine on the current input device, tapped into `feed`. False, with `error` set and
  /// everything stopped, when no microphone opens.
  private func openMicrophone() -> Bool {
    engine = AVAudioEngine()
    let node = engine.inputNode
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      error = "No microphone is available."
      // Clears the half-made request and lets go of the claim.
      stop()
      return false
    }
    let feed = self.feed
    let sink = recordTo == nil ? nil : audio
    let model = speech.flatMap { SpeechFeed(from: format, dictation: $0) }
    if model == nil, let speech {
      // This microphone's sound cannot be made into what the model takes: Apple Speech hears it,
      // after the words so far.
      SpeechEngine.shared.cancel(speech)
      self.speech = nil
      committed = latest
      committedSegments = segments
    }
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      if let model { model.append(buffer) } else { feed.append(buffer) }
      sink?.append(buffer)
      var peak: Float = 0
      if let data = buffer.floatChannelData?[0] {
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
      }
      // A buffer that lands after the microphone closed must not move the meter again.
      Task { @MainActor in
        guard let self, self.recording else { return }
        self.level = min(1, peak * 3)
      }
    }
    hasTap = true
    // A headset that connects, or a new default microphone, stops the engine without an error.
    inputWatch = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.inputChanged() }
    }
    do {
      engine.prepare()
      try engine.start()
      if !recording { recording = true }
      if starting { starting = false }
    } catch {
      self.error = error.localizedDescription
      stop()
      return false
    }
    return true
  }
  private func closeMicrophone() {
    if let inputWatch { NotificationCenter.default.removeObserver(inputWatch) }
    inputWatch = nil
    engine.stop()
    if hasTap {
      engine.inputNode.removeTap(onBus: 0)
      hasTap = false
    }
  }
  /// A new recognition on the open microphone; its words come after `committed`.
  private func recognize() {
    guard let recognizer, let onText else { return }
    generation += 1
    let current = generation
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.requiresOnDeviceRecognition = true
    req.shouldReportPartialResults = true
    request = req
    feed.set(req)
    recognitionStartedAt = Date()
    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      Task { @MainActor in
        guard let self, current == self.generation else { return }
        if let result {
          let transcription = result.bestTranscription
          self.latest = Self.joined(self.committed, transcription.formattedString)
          self.segments = self.committedSegments + transcription.segments.map {
            TalkSegment(text: $0.substring, confidence: Double($0.confidence))
          }
          onText(self.latest)
          if result.isFinal {
            self.recognitionEnded(error: nil)
            return
          }
        }
        if let error { self.recognitionEnded(error: error.localizedDescription) }
      }
    }
  }
  /// A recognition gave its final result or failed.
  private func recognitionEnded(error message: String?) {
    guard recording else {
      // `finish` closed the microphone and waits for this.
      finalWaiter?.resume()
      finalWaiter = nil
      stop()
      return
    }
    // The microphone is still open: the recognizer ended at a pause. The words so far stay and a
    // new recognition takes what follows. One that ends at once with nothing heard has failed, and
    // so has an error before any words (no speech, no recognizer).
    let heard = latest != committed
    let lasted = Date().timeIntervalSince(recognitionStartedAt) >= 2
    if heard || (lasted && (message == nil || !committed.isEmpty)) {
      committed = latest
      committedSegments = segments
      recognize()
      return
    }
    // Words already heard are kept for `finish`; the error is only shown when there are none.
    if let message, committed.isEmpty { error = message }
    stop()
  }
  /// macOS stopped the engine for a new input device or format: listening continues on the new
  /// microphone, after the words heard so far.
  private func inputChanged() {
    guard recording else { return }
    inputChanges += 1
    guard inputChanges <= 3 else {
      error = "The microphone keeps changing. Try again."
      stop()
      return
    }
    // The model goes on hearing the same dictation; only Apple Speech starts a new recognition.
    if speech == nil {
      committed = latest
      committedSegments = segments
    }
    // A kept recording cannot change format part way: this one is not kept.
    audio.discard()
    task?.cancel()
    request?.endAudio()
    closeMicrophone()
    guard openMicrophone() else { return }
    if speech == nil { recognize() }
  }
  private static func joined(_ before: String, _ next: String) -> String {
    before.isEmpty ? next : next.isEmpty ? before : before + " " + next
  }
  /// Stops listening, then waits (briefly) for the recognizer's final result instead of cancelling it.
  func finish() async -> String {
    guard recording else {
      startToken += 1
      claiming = false
      return latest
    }
    closeMicrophone()
    request?.endAudio()
    recording = false
    level = 0
    let current = generation
    if let speech {
      self.speech = nil
      let heard = await SpeechEngine.shared.finish(speech)
      // A stop or a later dictation meanwhile: its words are its own.
      guard current == generation else { return heard.text }
      latest = Self.joined(committed, heard.text)
      segments = committedSegments + heard.segments
      onText?(latest)
      stop()
      return latest
    }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      finalWaiter = c
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        // A later dictation's wait is its own: this timer never ends it early.
        guard self.generation == current else { return }
        self.finalWaiter?.resume()
        self.finalWaiter = nil
      }
    }
    let text = latest
    let english = language.map(SpeechModel.hears) == true
    stop()
    if english, !text.isEmpty { RelayController.shared?.relay.offerSpeechIfUseful() }
    return text
  }
  func stop() {
    startToken += 1
    generation += 1
    finalWaiter?.resume()
    finalWaiter = nil
    level = 0
    timeout?.cancel()
    timeout = nil
    closeMicrophone()
    if let speech { SpeechEngine.shared.cancel(speech) }
    speech = nil
    feed.set(nil)
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    recognizer = nil
    onText = nil
    recording = false
    claiming = false
  }
  /// Hides the last error and end note (the person dismissed them).
  func clearNotes() {
    error = nil
    endNote = nil
  }
}
