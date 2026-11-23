import AVFoundation
import CTranscribe
import Foundation
import SereinCore

/// The dictation model (SpeechModel) on transcribe.cpp: loaded once, kept warm, and listening
/// while the key is held, so letting go only waits for the last half second of sound. One
/// dictation has it at a time; a Dictation that cannot take it uses Apple Speech as before.
final class SpeechEngine: @unchecked Sendable {
  static let shared = SpeechEngine()
  struct Heard {
    var text = ""
    var segments: [TalkSegment] = []
  }

  /// Every call into the library is on this queue: a session takes one caller at a time.
  private let queue = DispatchQueue(label: "serein.speech-engine", qos: .userInteractive)
  // On `queue` only.
  private var model: OpaquePointer?
  private var session: OpaquePointer?
  private var current = 0
  private var streaming = false
  /// Sound not yet given to the model, and all of this dictation's sound for the fallback.
  private var pending: [Float] = []
  private var clip: [Float] = []
  private var onText: (@Sendable (String) -> Void)?
  // On the main actor only.
  @MainActor private(set) var ready = false
  @MainActor private var loading = false
  @MainActor private var taken = false
  @MainActor private var dictations = 0

  /// The Metal engine is measured on Apple silicon only.
  static var supported: Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
  }

  static func modelFile() -> URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    return SpeechModel.found(applicationSupport: support) {
      (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
  }

  /// The model takes about 731 MB, so launch loads it only when wake words are on and the person
  /// may talk at any moment. Otherwise the first dictation loads it (`begin`).
  static func warmsAtLaunch(wakeWords: Bool) -> Bool { wakeWords }

  /// Loads the model when its file is on this Mac, once. Until `ready`, dictation is Apple Speech.
  @MainActor func warm() async {
    guard Self.supported, !ready, !loading, let file = Self.modelFile() else { return }
    loading = true
    ready = await withCheckedContinuation { done in
      // Below the queue's own priority: loading must not slow the launch it runs beside.
      queue.async(qos: .utility) { done.resume(returning: self.load(file.path)) }
    }
    loading = false
  }

  /// Takes the engine for one dictation; `onText` gets the words so far, off the main thread.
  /// Nil when the model is not loaded or another dictation has it. The first call starts the load,
  /// and Apple Speech hears that dictation meanwhile.
  @MainActor func begin(onText: @escaping @Sendable (String) -> Void) -> Int? {
    guard ready else {
      // Checks and previews never load it on their own, as at launch.
      if !RunMode.automated, !RunMode.stress { Task { await warm() } }
      return nil
    }
    guard !taken else { return nil }
    taken = true
    dictations += 1
    let id = dictations
    queue.async {
      self.current = id
      self.pending = []
      self.clip = []
      self.onText = onText
      self.streaming = self.openStream()
    }
    return id
  }

  /// Sound for dictation `id`, 16 kHz mono. From any thread.
  func feed(_ samples: [Float], to id: Int) {
    queue.async {
      guard id == self.current, self.session != nil else { return }
      self.clip += samples
      guard self.streaming else { return }
      self.pending += samples
      guard self.pending.count >= SpeechModel.feedSamples else { return }
      if self.push(), let text = self.streamText() { self.onText?(text) }
    }
  }

  /// The key was let go: what dictation `id` heard, and the engine is free again.
  @MainActor func finish(_ id: Int) async -> Heard {
    let heard = await withCheckedContinuation { done in
      queue.async { done.resume(returning: self.end(id)) }
    }
    taken = false
    return heard
  }

  /// Dictation `id` was called off: nothing is heard, and the engine is free again.
  @MainActor func cancel(_ id: Int) {
    taken = false
    queue.async {
      guard id == self.current else { return }
      self.close()
    }
  }

  // MARK: On the queue

  private func load(_ path: String) -> Bool {
    // The library writes its progress to stderr unless it is given somewhere else to put it.
    transcribe_log_set({ _, _, _ in }, nil)
    guard transcribe_init_backends_default() == TRANSCRIBE_OK else { return false }
    var load = transcribe_model_load_params()
    transcribe_model_load_params_init(&load)
    load.backend = TRANSCRIBE_BACKEND_METAL
    var params = transcribe_session_params()
    transcribe_session_params_init(&params)
    // The graphics chip does the work; more threads only wait on it.
    params.n_threads = 1
    guard transcribe_model_load_file(path, &load, &model) == TRANSCRIBE_OK,
      transcribe_session_init(model, &params, &session) == TRANSCRIBE_OK
    else {
      transcribe_session_free(session)
      transcribe_model_free(model)
      session = nil
      model = nil
      return false
    }
    // Metal builds its kernels on first use (about a second). Eight seconds of silence fill the
    // model's window, so the first dictation does not pay for it.
    streaming = openStream()
    if streaming {
      pending = [Float](repeating: 0, count: 8 * SpeechModel.sampleRate)
      _ = push()
      var update = transcribe_stream_update()
      transcribe_stream_update_init(&update)
      _ = transcribe_stream_finalize(session, &update)
    }
    close()
    // Registered after the library's own exit work, so it runs before it.
    atexit { SpeechEngine.shared.unload() }
    return true
  }

  private func openStream() -> Bool {
    var run = transcribe_run_params()
    transcribe_run_params_init(&run)
    var window = transcribe_parakeet_buffered_stream_ext()
    transcribe_parakeet_buffered_stream_ext_init(&window)
    window.left_ms = Int32(SpeechModel.window.left)
    window.chunk_ms = Int32(SpeechModel.window.chunk)
    window.right_ms = Int32(SpeechModel.window.right)
    var stream = transcribe_stream_params()
    transcribe_stream_params_init(&stream)
    return withUnsafePointer(to: &window) {
      $0.withMemoryRebound(to: transcribe_ext.self, capacity: 1) { family in
        stream.family = family
        return transcribe_stream_begin(session, &run, &stream) == TRANSCRIBE_OK
      }
    }
  }

  /// Gives `pending` to the model. False, with the stream closed, when the model refuses it.
  private func push() -> Bool {
    var update = transcribe_stream_update()
    transcribe_stream_update_init(&update)
    let status = transcribe_stream_feed(session, pending, Int32(pending.count), &update)
    pending.removeAll(keepingCapacity: true)
    guard status == TRANSCRIBE_OK else {
      transcribe_stream_reset(session)
      streaming = false
      return false
    }
    return update.result_changed
  }

  private func streamText() -> String? {
    var text = transcribe_stream_text()
    transcribe_stream_text_init(&text)
    guard transcribe_stream_get_text(session, &text) == TRANSCRIBE_OK, let full = text.full_text else { return nil }
    return String(cString: full).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func end(_ id: Int) -> Heard {
    guard id == current else { return Heard() }
    defer { close() }
    var heard = Heard()
    if streaming {
      if !pending.isEmpty { _ = push() }
      var update = transcribe_stream_update()
      transcribe_stream_update_init(&update)
      if streaming, transcribe_stream_finalize(session, &update) == TRANSCRIBE_OK, let text = streamText() {
        heard = Heard(text: text, segments: segments())
      }
    }
    // The stream failed or heard nothing: the whole recording at once, so no words are lost.
    if heard.text.isEmpty, !clip.isEmpty {
      if streaming { transcribe_stream_reset(session) }
      streaming = false
      var run = transcribe_run_params()
      transcribe_run_params_init(&run)
      if transcribe_run(session, clip, Int32(clip.count), &run) == TRANSCRIBE_OK,
        let text = transcribe_full_text(session)
      {
        heard = Heard(
          text: String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines), segments: segments())
      }
    }
    return heard
  }

  /// The words of the last result, each with how sure the model was of it. A stream gives no
  /// word rows, only pieces.
  private func segments() -> [TalkSegment] {
    var pieces: [(text: String, sure: Float)] = []
    for i in 0..<transcribe_n_tokens(session) {
      var token = transcribe_token()
      transcribe_token_init(&token)
      if transcribe_get_token(session, i, &token) == TRANSCRIBE_OK, let text = token.text {
        pieces.append((String(cString: text), token.p))
      }
    }
    return SpeechModel.segments(pieces: pieces)
  }

  /// At exit only. The library's Metal device stops the process when a model is still loaded as
  /// it quits, which macOS reports as a crash.
  private func unload() {
    queue.sync {
      close()
      transcribe_session_free(session)
      transcribe_model_free(model)
      session = nil
      model = nil
    }
  }

  private func close() {
    if streaming { transcribe_stream_reset(session) }
    streaming = false
    current = 0
    onText = nil
    pending = []
    clip = []
  }
}

/// One open microphone's sound on its way to the speech engine, as the 16 kHz mono the model takes.
/// `append` is for the microphone tap's thread only.
final class SpeechFeed {
  private static let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechModel.sampleRate), channels: 1, interleaved: false)!
  private let converter: AVAudioConverter
  private let ratio: Double
  private let dictation: Int

  init?(from format: AVAudioFormat, dictation: Int) {
    guard let converter = AVAudioConverter(from: format, to: Self.format) else { return nil }
    // The first channel, as the level meter reads: a mixdown of an interface's unused inputs is quieter.
    if format.channelCount > 1 { converter.channelMap = [0] }
    self.converter = converter
    ratio = Self.format.sampleRate / format.sampleRate
    self.dictation = dictation
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    let room = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: room) else { return }
    var given = false
    var error: NSError?
    // "No data now" after the one buffer keeps the converter's filter state for the next one.
    converter.convert(to: out, error: &error) { _, status in
      if given {
        status.pointee = .noDataNow
        return nil
      }
      given = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
    SpeechEngine.shared.feed(
      Array(UnsafeBufferPointer(start: samples, count: Int(out.frameLength))), to: dictation)
  }
}
