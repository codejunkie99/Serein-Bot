#if DEBUG
import AppKit
import AVFoundation
import SereinCore
import SwiftUI

@MainActor enum ReplyStoryChecks {
  private static func check(_ value: Bool, _ label: String) throws {
    guard value else { throw SereinError.invalid("FAIL: " + label) }
    print("PASS: " + label)
  }
  static func run() async throws {
    guard let skill = PluginHost.builtInSkills.first(where: { $0.name == "explain-visually" }) else {
      throw SereinError.invalid("The bundled explain-visually skill is missing.")
    }
    let formats = try SkillParser.supportFile("references/formats.md", in: skill)
    try check(!skill.instructions.isEmpty && formats.contains("\"scenes\""), "The reusable visual explanation skill and its format reference are discoverable from the app bundle")
    try check(ReplyStory.Icon.allCases.allSatisfy { NSImage(systemSymbolName: $0.systemName, accessibilityDescription: nil) != nil }, "Every explanation pictogram exists on this Mac")
    let story = ReplyStory(title: "Why a saved write can still be lost", summary: "A successful write is not always a promise that the bytes reached permanent storage.",
      nodes: ["App", "Memory", "Drive"], scenes: [
        .init(title: "The app writes", body: "The operating system can hold those bytes in memory first. The app can see them, even though a power cut could still erase them.", focus: 1),
        .init(title: "A flush asks for a durable copy", body: "The system asks the drive to finish saving. The guarantee depends on the operating system and the drive honoring that request.", focus: 2),
        .init(title: "The limitation matters", body: "This explains the mechanism. It does not establish that every drive behaves correctly during a power failure.", focus: 2)
      ], caveat: "Illustration of a mechanism, not an independent hardware test. See the research report for exact passages and unresolved claims.")
    let encoded = try JSONEncoder().encode(story)
    let json = String(decoding: encoded, as: UTF8.self)
    try check(ReplyStory(json: json) == story && ReplyGraphic(language: "story", source: json) == .story(story), "A valid bounded visual explanation survives saving and becomes a native graphic")
    let parts = messagePieces("A short answer.\n```story\n" + json + "\n```\n")
    try check(parts.contains { if case .graphic(.story(let parsed), _, _) = $0.content { return parsed == story }; return false }, "The actual reply parser recognizes a completed story fence")
    try check(!messagePieces("```story\n" + json).contains { if case .graphic = $0.content { return true }; return false }, "An unfinished streamed story is never executed or partially rendered")
    let fenced = "```story\n" + json + "\n```"
    let compact = ReplyStoryPresentation(text: "Before: a limitation.\n\n" + fenced + "\n\nAfter: the next step.")
    try check(compact?.story == story && compact?.details == "Before: a limitation.\n\nAfter: the next step.", "A visual reply leads with its story and preserves every accompanying paragraph in More detail")
    try check(ReplyStoryPresentation(text: fenced + "\n" + fenced) == nil
      && ReplyStoryPresentation(text: fenced + "\n```swift\nprint(1)\n```") == nil
      && ReplyStoryPresentation(text: "```story\n" + json) == nil
      && ReplyStoryPresentation(text: "A plain answer.") == nil, "Multiple visuals, code, partial stories and plain text retain their ordinary presentation")
    var bad = story
    bad.scenes[0].focus = 99
    try check(!bad.valid, "A scene cannot address a nonexistent diagram node")
    bad = story; bad.nodes = ["same", "same"]
    try check(!bad.valid, "Duplicate diagram labels are rejected")
    bad = story; bad.scenes = Array(repeating: story.scenes[0], count: 6)
    try check(!bad.valid, "Visual explanations have a bounded scene count")
    bad = story; bad.summary = String(repeating: "word ", count: 100)
    try check(!bad.valid, "Oversized explanations stay out of the renderer")
    bad = story; bad.scenes[0].body = "api_key=sk-secret-secret-secret-secret"
    try check(!bad.valid, "Sensitive-looking text cannot enter an exported visual")
    try check(story.frame(at: -1).scene == 0 && story.frame(at: story.seconds(0)).scene == 1 && story.frame(at: 999).scene == story.scenes.count - 1, "Playback timing handles start, scene boundaries and the ending")
    try check(story.duration >= 21 && story.duration <= 54 && story.narration.contains(story.caveat), "Playback is bounded and spoken explanations retain the caveat")
    var spoken = story
    spoken.scenes[0].narration = "Think of memory as a temporary tray. The bytes are there, but they have not reached the drive yet."
    try check(spoken.valid && spoken.spokenScenes[0].contains(spoken.summary)
      && spoken.spokenScenes[0].contains(spoken.scenes[0].narration!)
      && spoken.spokenScenes.last!.contains(spoken.caveat), "A conversational script changes the speech while retaining the takeaway and spoken caveat")
    spoken.scenes[0].narration = "api_key=sk-secret-secret-secret-secret"
    try check(!spoken.valid, "Narration cannot bypass the visual's sensitive-text checks")
    var expressive = story
    expressive.scenes[0].narration = "Is it safe? Not yet. It's still in memory."
    expressive.scenes[0].emphasis = "still in memory"
    try check(expressive.valid && ReplyStory(json: String(decoding: try JSONEncoder().encode(expressive), as: UTF8.self)) == expressive,
      "Spoken emphasis survives saving without changing the narration or evidence")
    expressive.scenes[0].emphasis = "a claim that was never spoken"
    try check(!expressive.valid, "Emphasis cannot introduce words absent from the spoken explanation")
    expressive.scenes[0].emphasis = String(repeating: "a", count: 61)
    expressive.scenes[0].narration = expressive.scenes[0].emphasis
    try check(!expressive.valid, "Oversized emphasis is rejected")
    expressive.scenes[0].narration = "A & B <voice name=\"other\">can't</voice> change the voice."
    expressive.scenes[0].emphasis = "<voice name=\"other\">"
    let safeMarkup = StoryNarration.markup(for: expressive, scene: 0)
    try check(expressive.valid && !safeMarkup.contains("<voice ") && safeMarkup.contains("&amp;")
      && safeMarkup.contains("<prosody rate=\"92%\" pitch=\"+3%\">&lt;voice")
      && AVSpeechUtterance(ssmlRepresentation: safeMarkup) != nil,
      "Narration and emphasis are escaped before host-owned speech markup is created")
    let chosenVoice = try StoryNarration.voice(for: story)
    let delivered = StoryNarration.utterance(for: story, scene: 0, voice: chosenVoice)
    try check(delivered.voice?.identifier == chosenVoice.identifier
      && StoryNarration.markup(for: story, scene: 0).contains("<break time=\"350ms\"/>")
      && StoryNarration.markup(for: story, scene: story.scenes.count - 1).contains("<break time=\"350ms\"/>"),
      "Listen and video use the selected voice with breathing room before explanation and caveat")
    let measured = [4.5, 22.25, 9.0]
    try check(story.frame(at: 4.49, durations: measured).scene == 0
      && story.frame(at: 4.5, durations: measured).scene == 1
      && story.frame(at: 26.75, durations: measured).scene == 2,
      "Measured speech lengths determine visual scene boundaries without truncating a longer spoken scene")
    var motion = story
    motion.scenes[0].visual = .init(kind: .transfer, from: 0, to: 1, headline: "A copy moves into memory")
    try check(motion.valid && ReplyStory(json: String(decoding: try JSONEncoder().encode(motion), as: UTF8.self)) == motion,
      "A bounded motion plan survives saving alongside the spoken explanation")
    motion.scenes[0].visual?.to = 99
    try check(!motion.valid, "Motion cannot address an object outside its story")
    motion.scenes[0].visual = .init(kind: .release, from: 1, to: 1)
    try check(!motion.valid, "A transfer must have distinct source and destination objects")
    motion.scenes[0].visual = .init(kind: .result, figures: [.init(label: "Unconfirmed", value: -1)])
    try check(!motion.valid, "Negative outcome counts are rejected")
    motion.scenes[0].visual = .init(kind: .focus, headline: "api_key=sk-secret-secret-secret-secret")
    try check(!motion.valid, "Motion labels retain the same sensitive-text boundary")
    try check(story.visual(0).kind == .focus, "Legacy stories get an illustration without an invented causal action")
    let cacheKey = try StoryExport.cacheURL(story: story, palette: .light, sourceLine: nil, reduceMotion: false)
    try check(cacheKey != StoryExport.cacheURL(story: story, palette: .dusk, sourceLine: nil, reduceMotion: false)
      && cacheKey != StoryExport.cacheURL(story: story, palette: .light, sourceLine: "Changed source record", reduceMotion: false)
      && cacheKey != StoryExport.cacheURL(story: story, palette: .light, sourceLine: nil, reduceMotion: true), "Video caches distinguish palette, source attribution and reduced-motion preferences")
    let remoteVideo = await StoryExport.playable(URL(string: "https://example.com/movie.mp4")!)
    try check(!remoteVideo, "Inline story playback refuses remote media")
    var research = try ResearchClaimFixtures.job()
    let before = research
    let recap = research.visualStory
    try check(recap.valid && research == before, "A research visual derives from saved facts without changing evidence or starting work")
    research.sources = [research.sources[0]]
    research.sources[0].findings = []
    research.sources[0].claimCheck = nil
    try check(research.visualStory.summary.contains("did not establish"), "No available claims never appears as independent support")
    guard let path = ProcessInfo.processInfo.environment["SEREIN_STORY_CAPTURES"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var actual = story
    if let source = ProcessInfo.processInfo.environment["SEREIN_STORY_RESEARCH"] {
      let job = try JSONDecoder().decode(ResearchJob.self, from: Data(contentsOf: URL(fileURLWithPath: source)))
      try job.validate()
      actual = job.visualStory
    }
    if let path = ProcessInfo.processInfo.environment["SEREIN_STORY_JSON"] {
      guard let saved = ReplyStory(json: try String(contentsOfFile: path, encoding: .utf8)) else { throw SereinError.invalid("The saved story is invalid.") }
      actual = saved
    }
    for palette in [Palette.light, .dusk] {
      let name = palette.isDark ? "dark" : "light"
      let images = try StoryExport.frames(story: actual, palette: palette, sourceLine: "Saved source snapshots · see the full report in Serein")
      for index in images.indices {
        let data = NSBitmapImageRep(cgImage: images[index]).representation(using: .png, properties: [:])!
        try data.write(to: directory.appendingPathComponent("scene-\(name)-\(index).png"))
      }
      for width in [360, 560] {
        let renderer = ImageRenderer(content: ReplyStoryCard(story: actual, details: "The saved evidence remains here.")
          .frame(width: CGFloat(width - 40)).padding(20).environment(\.palette, palette)
          .environment(\.colorScheme, palette.isDark ? .dark : .light).environment(\.sereinReducedEffects, true).background(palette.background))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
          throw SereinError.invalid("The native explanation card could not be rendered.")
        }
        try data.write(to: directory.appendingPathComponent("card-\(name)-\(width).png"))
      }
    }
    for kind in ReplyStory.Visual.Kind.allCases {
      var sample = story
      sample.icons = [.app, .memory, .disk]
      sample.scenes[0].visual = .init(kind: kind, from: 0, to: 1, headline: "See what changes",
        figures: kind == .result ? [.init(label: "Supported", value: 0), .init(label: "Disputed", value: 0), .init(label: "Unconfirmed", value: 3)] : nil)
      try check(sample.valid, "The " + kind.rawValue + " composition accepts its bounded visual plan")
      let artwork = StoryMotion(story: sample)
      let early = try artwork.image(scene: 0, progress: 0.12)
      let late = try artwork.image(scene: 0, progress: 0.68)
      let region = CGRect(x: 100, y: 235, width: 1080, height: 365)
      guard let first = early.cropping(to: region)?.dataProvider?.data,
        let last = late.cropping(to: region)?.dataProvider?.data else { throw SereinError.invalid("The motion stage could not be inspected.") }
      try check((first as Data) != (last as Data), "The " + kind.rawValue + " objects move inside the scene, beyond text or a progress bar")
      for (name, image) in [("early", early), ("late", late)] {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
          .write(to: directory.appendingPathComponent("motion-" + kind.rawValue + "-" + name + ".png"))
      }
    }
    let voice = try StoryNarration.voice(for: actual)
    let clips = try await StoryNarration.render(story: actual, voice: voice)
    let lengths = clips.map(\.sceneSeconds)
    try check(clips.count == actual.scenes.count && clips.allSatisfy { $0.seconds > 0 }, "Every scene produces its own measured, audible narration clip")
    let picture = try await StoryExport.movie(story: actual, sourceLine: "Saved source snapshots · see the full report in Serein", reduceMotion: false, durations: lengths)
    let silentAccepted = await StoryExport.playable(picture)
    try check(!silentAccepted, "A silent legacy video cannot satisfy the narrated-video cache")
    let url = try await StoryNarration.combine(video: picture, clips: clips)
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    let size = try await video.first?.load(.naturalSize)
    try check(video.count == 1 && audio.count == 1 && size == CGSize(width: 1920, height: 1080)
      && abs(duration - lengths.reduce(0, +)) < 0.1, "Export creates a 1080p MP4 with embedded narration and a video timeline matching the measured speech")
    let reader = try AVAssetReader(asset: asset)
    let sound = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
    reader.add(sound)
    guard reader.startReading() else { throw reader.error ?? SereinError.invalid("The exported audio could not be read.") }
    var peak: Float = 0
    while let sample = sound.copyNextSampleBuffer() {
      if let block = CMSampleBufferGetDataBuffer(sample) {
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        if copied == kCMBlockBufferNoErr {
          data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count - 3, by: 4) { peak = max(peak, abs(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))) }
          }
        }
      }
    }
    try check(reader.status == .completed && peak > 0.01, "The exported AAC track decodes to audible speech, not an empty or silent audio track")
    let timings: [[String: Any]] = clips.indices.map { index in
      ["scene": index, "text": actual.spokenScenes[index], "start": lengths.prefix(index).reduce(0, +),
       "speech_start": lengths.prefix(index).reduce(0, +) + StoryNarration.lead, "speech_seconds": clips[index].seconds,
       "scene_seconds": lengths[index], "voice": voice.identifier, "voice_quality": voice.quality.rawValue,
       "delivery": StoryNarration.deliveryVersion]
    }
    try JSONSerialization.data(withJSONObject: timings, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("narration-timing.json"))
    try Data(contentsOf: url).write(to: directory.appendingPathComponent("research-explained.mp4"), options: .atomic)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let frame = try await generator.image(at: CMTime(seconds: duration - 2, preferredTimescale: 600)).image
    let data = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!
    try data.write(to: directory.appendingPathComponent("movie-last-scene.png"))
    try check(true, "Rendered light, dark, narrow and wide cards plus decoded the exported video's final scene")
    let cache = directory.appendingPathComponent("playback-cache", isDirectory: true)
    let saved = try await StoryExport.playbackFile(story: actual, palette: .light, sourceLine: nil, reduceMotion: false, directory: cache)
    let originalDate = try saved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let reused = try await StoryExport.playbackFile(story: actual, palette: .light, sourceLine: nil, reduceMotion: false, directory: cache)
    let reusedDate = try reused.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    try check(saved == reused && originalDate == reusedDate, "An existing video is reused without rendering or rewriting it")
    let player = AVPlayer(url: reused)
    try check(player.rate == 0 && (player.currentItem?.asset as? AVURLAsset)?.url == reused, "The inline player binds the real saved MP4 and starts paused")
    try Data("broken cached video".utf8).write(to: saved, options: .atomic)
    let repaired = try await StoryExport.playbackFile(story: actual, palette: .light, sourceLine: nil, reduceMotion: false, directory: cache)
    let repairedPlayable = await StoryExport.playable(repaired)
    try check(repaired == saved && repairedPlayable, "A corrupt video cache is regenerated from the saved story")
    let cancelled = Task { try await StoryExport.movie(story: actual, sourceLine: "Saved source snapshots · see the full report in Serein", reduceMotion: false, durations: lengths) }
    cancelled.cancel()
    do { _ = try await cancelled.value; throw SereinError.invalid("Cancelled video rendering unexpectedly completed.") }
    catch is CancellationError { try check(true, "Cancelling playback preparation cancels the video encoder") }
    let cancelledSpeech = Task { try await StoryNarration.render(story: actual, voice: voice) }
    cancelledSpeech.cancel()
    do { _ = try await cancelledSpeech.value; throw SereinError.invalid("Cancelled narration unexpectedly completed.") }
    catch is CancellationError { try check(true, "Cancelling narration stops speech preparation") }
  }
}
#endif
