import AVFoundation
import Foundation
import SereinCore

/// Speech is generated on this Mac. Each scene owns its audio; measured clip lengths drive
/// both the visual timeline and the final MP4's audio track, including pauses and the caveat.
enum StoryNarration {
  static let lead = 0.35
  static let tail = 0.4
  static let deliveryVersion = SpeechDelivery.version
  struct Clip {
    let file: URL
    let seconds: Double
    var sceneSeconds: Double { seconds + StoryNarration.lead + StoryNarration.tail }
  }

  static func voice(for story: ReplyStory) throws -> AVSpeechSynthesisVoice {
    try SpeechDelivery.voice(for: story.summary + " " + story.scenes.map(\.body).joined(separator: " "))
  }

  private static func passages(for story: ReplyStory, scene: Int) -> [SpeechDelivery.Passage] {
    let item = story.scenes[scene]
    return [scene == 0 ? .init(text: story.summary) : nil,
      .init(text: item.narration ?? item.body, emphasis: item.emphasis),
      scene == story.scenes.count - 1 ? .init(text: story.caveat) : nil].compactMap { $0 }
  }

  static func markup(for story: ReplyStory, scene: Int) -> String {
    SpeechDelivery.markup(passages(for: story, scene: scene))
  }

  static func utterance(for story: ReplyStory, scene: Int, voice: AVSpeechSynthesisVoice) -> AVSpeechUtterance {
    SpeechDelivery.utterance(passages(for: story, scene: scene), voice: voice)
  }

  @MainActor static func render(story: ReplyStory, voice: AVSpeechSynthesisVoice) async throws -> [Clip] {
    guard story.valid else { throw SereinError.invalid("The visual explanation is not valid.") }
    let speaker = StorySpeechWriter()
    var clips: [Clip] = []
    for scene in story.scenes.indices {
      try Task.checkCancellation()
      clips.append(try await speaker.write(utterance(for: story, scene: scene, voice: voice)))
    }
    return clips
  }

  static func combine(video: URL, clips: [Clip]) async throws -> URL {
    try Task.checkCancellation()
    let composition = AVMutableComposition()
    let asset = AVURLAsset(url: video)
    guard let source = try await asset.loadTracks(withMediaType: .video).first,
      let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let speech = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw SereinError.invalid("The narrated video could not be assembled.")
    }
    try picture.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: source, at: .zero)
    var start = 0.0
    for clip in clips {
      try Task.checkCancellation()
      let audio = AVURLAsset(url: clip.file)
      guard let track = try await audio.loadTracks(withMediaType: .audio).first else {
        throw SereinError.invalid("A narration scene has no audio.")
      }
      try speech.insertTimeRange(CMTimeRange(start: .zero, duration: try await audio.load(.duration)), of: track,
        at: CMTime(seconds: start + lead, preferredTimescale: 60000))
      start += clip.sceneSeconds
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("serein-narrated-" + UUID().uuidString + ".mp4")
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
      throw SereinError.invalid("Narrated video export is unavailable.")
    }
    export.outputURL = file; export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true
    // Only cancellation crosses the export queue; setup and result inspection stay here.
    nonisolated(unsafe) let cancellableExport = export
    await withTaskCancellationHandler { await export.export() } onCancel: { cancellableExport.cancelExport() }
    try Task.checkCancellation()
    guard export.status == .completed else { throw export.error ?? SereinError.invalid("The narrated video could not be saved.") }
    return file
  }
}

/// AVSpeechSynthesizer owns its callback queue. Consume each buffer there before it can be
/// reused, then deliver one result on the main actor. No callback retains a transient buffer.
private final class StorySpeechFile: @unchecked Sendable {
  private let lock = NSLock()
  private let url = FileManager.default.temporaryDirectory.appendingPathComponent("serein-speech-" + UUID().uuidString + ".caf")
  private var file: AVAudioFile?
  private var frames: Int64 = 0
  private var sampleRate = 0.0
  private var audible = false
  private var ended = false
  func append(_ buffer: AVAudioBuffer) -> Result<StoryNarration.Clip, Error>? {
    lock.lock(); defer { lock.unlock() }
    guard !ended else { return nil }
    do {
      guard let pcm = buffer as? AVAudioPCMBuffer else { throw SereinError.invalid("The narration returned an unsupported audio format.") }
      if pcm.frameLength == 0 {
        ended = true; file = nil
        guard frames > 0, sampleRate > 0, audible else { throw SereinError.invalid("The selected voice did not produce audible narration.") }
        return .success(.init(file: url, seconds: Double(frames) / sampleRate))
      }
      if file == nil {
        sampleRate = pcm.format.sampleRate
        file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
          commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
      }
      guard sampleRate > 0, Double(frames + Int64(pcm.frameLength)) / sampleRate <= 120 else {
        throw SereinError.invalid("A narration scene exceeded two minutes. Shorten its spoken text and try again.")
      }
      if let samples = pcm.floatChannelData?[0] {
        for index in 0..<Int(pcm.frameLength) where abs(samples[index]) > 0.0001 { audible = true; break }
      } else if let samples = pcm.int16ChannelData?[0] {
        for index in 0..<Int(pcm.frameLength) where samples[index] != 0 { audible = true; break }
      }
      try file?.write(from: pcm)
      frames += Int64(pcm.frameLength)
      return nil
    } catch { ended = true; file = nil; return .failure(error) }
  }
  func cancel() { lock.lock(); defer { lock.unlock() }; ended = true; file = nil }
}

@MainActor final class StorySpeechWriter {
  private let synthesizer = AVSpeechSynthesizer()
  private var pending: CheckedContinuation<StoryNarration.Clip, Error>?
  private var timeout: Task<Void, Never>?
  private var sink: StorySpeechFile?
  private var generation = UUID()

  func write(_ words: AVSpeechUtterance) async throws -> StoryNarration.Clip {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let file = StorySpeechFile()
        let token = UUID(); generation = token
        pending = continuation; sink = file
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
          self?.finish(.failure(SereinError.invalid("The narration voice did not finish. Try again.")), token: token)
        }
        synthesizer.write(words) { [weak self] buffer in
          guard let result = file.append(buffer) else { return }
          Task { @MainActor in self?.finish(result, token: token) }
        }
        if Task.isCancelled { finish(.failure(CancellationError()), token: token) }
      }
    } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), token: self?.generation) } }
  }

  private func finish(_ result: Result<StoryNarration.Clip, Error>, token: UUID?) {
    guard token == generation, let pending else { return }
    self.pending = nil
    timeout?.cancel(); timeout = nil
    sink?.cancel(); sink = nil
    if case .failure = result { synthesizer.stopSpeaking(at: .immediate) }
    pending.resume(with: result)
  }
}
