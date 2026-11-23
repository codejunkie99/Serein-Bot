import CoreGraphics
import AVFoundation
import CryptoKit
import SereinCore

enum StoryExport {
  /// The saved story is the source of truth. Its local video cache can be reused after restart
  /// or regenerated if macOS clears it; no model call or arbitrary media URL is involved.
  static func cacheURL(story: ReplyStory, palette: Palette, sourceLine: String?, reduceMotion: Bool, directory: URL? = nil) throws -> URL {
    guard story.valid else { throw SereinError.invalid("The visual explanation is not valid.") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var key = try encoder.encode(story)
    let voice = try StoryNarration.voice(for: story)
    key.append(Data("\nvideo-v4-voice\n\(StoryNarration.deliveryVersion)\n\(voice.identifier)\n\(voice.quality.rawValue)\n\(palette.rawValue)\n\(sourceLine ?? "")\n\(reduceMotion)".utf8))
    let name = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Serein/ReplyVideos", isDirectory: true)
    return root.appendingPathComponent(name + ".mp4")
  }

  static func playable(_ url: URL) async -> Bool {
    guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 50_000_000 else { return false }
    let asset = AVURLAsset(url: url)
    guard (try? await asset.load(.isPlayable)) == true else { return false }
    guard (try? await asset.loadTracks(withMediaType: .video).isEmpty) == false else { return false }
    return (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false
  }

  @MainActor static func playbackFile(story: ReplyStory, palette: Palette, sourceLine: String?, reduceMotion: Bool, directory: URL? = nil) async throws -> URL {
    try Task.checkCancellation()
    let target = try cacheURL(story: story, palette: palette, sourceLine: sourceLine, reduceMotion: reduceMotion, directory: directory)
    if await playable(target) { try Task.checkCancellation(); return target }
    try Task.checkCancellation()
    let clips = try await StoryNarration.render(story: story, voice: StoryNarration.voice(for: story))
    let picture = try await movie(story: story, sourceLine: sourceLine, reduceMotion: reduceMotion, durations: clips.map(\.sceneSeconds))
    let temporary = try await StoryNarration.combine(video: picture, clips: clips)
    try Task.checkCancellation()
    guard await playable(temporary) else { throw SereinError.invalid("The narrated video could not be verified. Try again.") }
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contentsOf: temporary).write(to: target, options: .atomic)
    return target
  }

  @MainActor static func frames(story: ReplyStory, palette: Palette, sourceLine: String?) throws -> [CGImage] {
    guard story.valid else { throw SereinError.invalid("The visual explanation is not valid.") }
    let artwork = StoryMotion(story: story, sourceLine: sourceLine)
    return try story.scenes.indices.map { try artwork.image(scene: $0) }
  }

  /// A local motion-graphics MP4. The renderer draws bounded visual actions at every frame;
  /// it cannot execute model content or fetch media. Narration supplies the measured timeline.
  static func movie(story: ReplyStory, sourceLine: String? = nil, reduceMotion: Bool, durations: [Double]) async throws -> URL {
    guard story.valid, durations.count == story.scenes.count,
      durations.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 121 }) else {
      throw SereinError.invalid("The explanation frames or speech timings are incomplete.")
    }
    let duration = durations.reduce(0, +)
    let encoding = Task.detached(priority: .utility) {
      let motion = StoryMotion(story: story, sourceLine: sourceLine)
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("serein-story-" + UUID().uuidString + ".mp4")
      let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]
      ])
      input.expectsMediaDataInRealTime = false
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
      ])
      guard writer.canAdd(input) else { throw SereinError.invalid("Video export is unavailable.") }
      writer.add(input)
      guard writer.startWriting() else { throw writer.error ?? SereinError.invalid("Video export could not start.") }
      writer.startSession(atSourceTime: .zero)
      let fps: Int32 = 30
      let count = Int(ceil(duration * Double(fps)))
      do {
        for number in 0..<count {
          try Task.checkCancellation()
          while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status != .writing { throw writer.error ?? SereinError.invalid("Video encoding stopped.") }
            try await Task.sleep(for: .milliseconds(3))
          }
          var pixel: CVPixelBuffer?
          guard let pool = adaptor.pixelBufferPool,
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
            throw SereinError.invalid("The video frame could not be allocated.")
          }
          CVPixelBufferLockBaseAddress(pixel, [])
          guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 1920, height: 1080,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            CVPixelBufferUnlockBaseAddress(pixel, [])
            throw SereinError.invalid("The video frame could not be drawn.")
          }
          let time = Double(number) / Double(fps)
          let state = story.frame(at: time, durations: durations)
          context.scaleBy(x: 1.5, y: 1.5)
          motion.draw(in: context, scene: state.scene, progress: reduceMotion ? 0.8 : state.progress)
          CVPixelBufferUnlockBaseAddress(pixel, [])
          guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(number), timescale: fps)) else {
            throw writer.error ?? SereinError.invalid("The video frame could not be saved.")
          }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(count), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SereinError.invalid("The video could not be completed.") }
        return file
      } catch { writer.cancelWriting(); throw error }
    }
    return try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
  }
}
