import AppKit
import AVFoundation
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// Only a single complete story with accompanying prose gets the compact presentation.
/// Mixed media/code and multiple visuals keep the ordinary renderer; no content is dropped.
struct ReplyStoryPresentation {
  let story: ReplyStory
  let details: String?
  init?(text: String) {
    var found: ReplyStory?
    var prose: [String] = []
    for piece in messagePieces(text) {
      switch piece.content {
      case .graphic(.story(let story), _, _):
        guard found == nil else { return nil }
        found = story
      case .prose(let words):
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { prose.append(words) }
      default: return nil
      }
    }
    guard let found else { return nil }
    story = found
    details = prose.isEmpty ? nil : prose.joined(separator: "\n\n")
  }
}

/// The same bounded story is a readable diagram, an inline video, a PNG and a captioned
/// movie. Nothing autoplays or speaks on arrival. Evidence remains available below the summary.
struct ReplyStoryCard: View {
  let story: ReplyStory
  var details: String? = nil
  var detailsTitle: String = "More detail"
  var sourceLine: String? = nil
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sereinReducedEffects) private var reducedEffects
  @State private var scene = 0
  @State private var player: AVPlayer?
  @State private var showingVideo = false
  @State private var showingSteps = false
  @State private var preparingVideo = false
  @State private var videoTask: Task<Void, Never>?
  @State private var expanded = false
  @State private var exporting = false
  @State private var showingSources = false
  @State private var exportNote: String?
  @State private var voice = AVSpeechSynthesizer()

  private var selected: Int { min(scene, story.scenes.count - 1) }
  private var cachedVideo: URL? {
    try? StoryExport.cacheURL(story: story, palette: p, sourceLine: sourceLine, reduceMotion: reduceMotion || reducedEffects)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: story.title).font(UIStyle.font(20, weight: .semibold)).foregroundStyle(p.ink)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: story.summary).font(AssistantType.body).foregroundStyle(p.ink)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      if showingVideo, let player {
        StoryVideoPlayer(player: player, title: story.title)
      } else if !showingSteps {
        StoryMotionPoster(story: story, scene: selected)
      } else {
        StoryDiagram(story: story, scene: selected, large: false, choose: { node in
          if let index = story.scenes.firstIndex(where: { $0.focus == node }) { scene = index }
        })
          .animation(reduceMotion || reducedEffects ? nil : .easeInOut(duration: 0.3), value: selected)
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: story.scenes[selected].title).font(AssistantType.name).foregroundStyle(p.ink)
          Text(verbatim: story.scenes[selected].body).font(AssistantType.body).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
      }
      playback
      Text(verbatim: story.caveat).font(AssistantType.meta).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let exportNote { Text(verbatim: exportNote).font(AssistantType.meta).foregroundStyle(p.secondary) }
      if let details {
        Divider()
        DisclosureGroup(detailsTitle, isExpanded: $expanded) {
          MessageContent(text: details, showsCopyButton: true).padding(.top, 10)
        }.font(AssistantType.meta).foregroundStyle(p.ink)
      }
    }
    .padding(18).frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading).assistantCard(p)
    .accessibilityElement(children: .contain)
    .popover(isPresented: $showingSources) {
      Text(verbatim: sourceLine ?? "No source record was saved with this explanation.")
        .font(AssistantType.body).padding(18).frame(maxWidth: 360)
    }
    .task(id: cachedVideo) {
      videoTask?.cancel(); player?.pause(); player = nil; showingVideo = false
      guard let file = cachedVideo, await StoryExport.playable(file), !Task.isCancelled else { return }
      player = AVPlayer(url: file); showingVideo = true
    }
    .onChange(of: story) { _, _ in scene = 0 }
    .onDisappear { videoTask?.cancel(); player?.pause(); voice.stopSpeaking(at: .immediate) }
  }

  private var playback: some View {
    HStack(spacing: 10) {
      Button {
        if showingVideo { player?.pause(); showingVideo = false; showingSteps = true }
        else { playVideo() }
      } label: {
        Label(preparingVideo ? "Preparing video…" : showingVideo ? "Read steps" : "Play video",
          systemImage: preparingVideo ? "clock" : showingVideo ? "text.alignleft" : "play.fill")
      }.buttonStyle(PrimaryButton()).fixedSize().disabled(preparingVideo || exporting)
      Spacer(minLength: 0)
      if !showingVideo && !showingSteps {
        Button("Read steps") { showingSteps = true }.buttonStyle(QuietButton())
      }
      if !showingVideo && showingSteps {
        Button { step(-1) } label: { Image(systemName: "chevron.left") }
          .buttonStyle(QuietButton()).disabled(scene == 0).accessibilityLabel("Previous scene")
        Button { step(1) } label: { Image(systemName: "chevron.right") }
          .buttonStyle(QuietButton()).disabled(scene == story.scenes.count - 1).accessibilityLabel("Next scene")
      }
      Menu {
        Button("Listen") {
          if voice.isSpeaking { voice.stopSpeaking(at: .immediate) }
          else {
            player?.pause()
            do {
              let selected = try StoryNarration.voice(for: story)
              for index in story.scenes.indices {
                let words = StoryNarration.utterance(for: story, scene: index, voice: selected)
                words.preUtteranceDelay = StoryNarration.lead
                words.postUtteranceDelay = StoryNarration.tail
                voice.speak(words)
              }
            } catch { exportNote = error.localizedDescription }
          }
        }
        Button("Save image…") { save(video: false) }.disabled(exporting)
        Button(exporting ? "Making video…" : "Save narrated video…") { save(video: true) }.disabled(exporting || preparingVideo)
        if sourceLine != nil { Button("Sources") { showingSources = true } }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More explanation options")
    }.font(AssistantType.meta)
  }
  private func step(_ delta: Int) {
    withAnimation(reduceMotion || reducedEffects ? nil : .easeInOut(duration: 0.2)) { scene += delta }
  }
  private func playVideo() {
    voice.stopSpeaking(at: .immediate)
    if let player {
      if let duration = player.currentItem?.duration.seconds, player.currentTime().seconds >= duration { player.seek(to: .zero) }
      showingVideo = true; player.play(); return
    }
    preparingVideo = true; exportNote = nil
    videoTask = Task { @MainActor in
      defer { preparingVideo = false }
      do {
        let file = try await StoryExport.playbackFile(story: story, palette: p, sourceLine: sourceLine, reduceMotion: reduceMotion || reducedEffects)
        try Task.checkCancellation()
        let video = AVPlayer(url: file)
        player = video; showingVideo = true; video.play()
      } catch is CancellationError { }
      catch { exportNote = error.localizedDescription }
    }
  }
  private func save(video: Bool) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [video ? .mpeg4Movie : .png]
    panel.nameFieldStringValue = video ? "Serein explanation.mp4" : "Serein explanation.png"
    panel.message = video ? "An illustrated motion-graphics video with synchronized voice narration." : "Save the current explanation scene."
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    exportNote = nil
    do {
      if !video {
        let frames = try StoryExport.frames(story: story, palette: p, sourceLine: sourceLine)
        let bitmap = NSBitmapImageRep(cgImage: frames[selected])
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SereinError.invalid("The image could not be created.") }
        try data.write(to: destination, options: .atomic)
        exportNote = "Image saved."
        return
      }
      exporting = true
      Task { @MainActor in
        defer { exporting = false }
        do {
          let file = try await StoryExport.playbackFile(story: story, palette: p, sourceLine: sourceLine, reduceMotion: reduceMotion || reducedEffects)
          try Data(contentsOf: file).write(to: destination, options: .atomic)
          exportNote = "Narrated video saved."
        } catch { exportNote = error.localizedDescription }
      }
    } catch { exportNote = error.localizedDescription }
  }
}

/// Labels and focus carry the meaning; colour and motion only reinforce it.
private struct StoryDiagram: View {
  let story: ReplyStory
  let scene: Int
  var large: Bool
  var choose: ((Int) -> Void)? = nil
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: large ? 14 : 5) {
      ForEach(story.nodes.indices, id: \.self) { index in
        if index > 0 { Image(systemName: "arrow.right").font(.system(size: large ? 20 : 10)).foregroundStyle(p.secondary).accessibilityHidden(true) }
        if let choose {
          Button { choose(index) } label: { node(index) }.buttonStyle(.plain)
            .help("Show " + story.nodes[index])
        } else { node(index) }
      }
    }.padding(.vertical, large ? 8 : 14)
  }
  private func node(_ index: Int) -> some View {
    VStack(spacing: large ? 12 : 8) {
          Group {
            if let icon = story.icons?[index] { Image(systemName: icon.systemName).font(.system(size: large ? 24 : 15, weight: .medium)) }
            else { Text("\(index + 1)").font(UIStyle.font(large ? 24 : 15, weight: .semibold)) }
          }
            .frame(width: large ? 48 : 30, height: large ? 48 : 30)
            .background(index == story.scenes[scene].focus ? p.ink : p.track, in: Circle())
            .foregroundStyle(index == story.scenes[scene].focus ? p.background : p.secondary)
          Text(verbatim: story.nodes[index]).font(UIStyle.font(large ? 24 : 12, weight: .medium))
            .foregroundStyle(p.ink).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
          Capsule().fill(index == story.scenes[scene].focus ? p.ink : .clear).frame(width: large ? 36 : 20, height: 3)
        }.frame(maxWidth: .infinity, alignment: .top)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(index + 1). \(story.nodes[index])\(index == story.scenes[scene].focus ? ", current step" : "")")
  }
}

/// A still frame before Play; no animation or speech starts just because a reply arrives.
private struct StoryMotionPoster: View {
  let story: ReplyStory
  let scene: Int
  @State private var poster: CGImage?
  var body: some View {
    Group {
      if let poster { Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fit) }
      else { Color.clear.aspectRatio(16.0 / 9, contentMode: .fit) }
    }
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(story.scenes[scene].title + ". " + story.scenes[scene].body)
    .task(id: scene) { poster = try? StoryMotion(story: story).image(scene: scene) }
    .onChange(of: story) { _, _ in poster = try? StoryMotion(story: story).image(scene: scene) }
  }
}

extension ReplyStory.Icon {
  var systemName: String {
    switch self {
    case .page: return "doc.text"
    case .search: return "magnifyingglass"
    case .compare: return "square.stack.3d.up"
    case .result: return "list.bullet.rectangle"
    case .app: return "macwindow"
    case .memory: return "memorychip"
    case .disk: return "externaldrive"
    case .person: return "person"
    case .clock: return "clock"
    case .warning: return "exclamationmark.triangle"
    case .parcel: return "shippingbox"
    case .truck: return "truck.box"
    case .cloud: return "cloud"
    case .energy: return "bolt"
    }
  }
}

/// Observes notebook loading as well as delivery, so an old saved report gets its visual as
/// soon as the store opens. No migration or repeat model call is needed.
struct ResearchStoryReport: View {
  @ObservedObject var research: ResearchCoordinator
  let message: AgentMessage
  var body: some View {
    if let job = research.jobs.first(where: { $0.messageID == message.id && $0.state == .ready }), job.visualStory.valid {
      VStack(alignment: .leading, spacing: 12) {
        ReplyStoryCard(story: job.visualStory, details: message.text, detailsTitle: "Evidence and sources",
          sourceLine: "Sources considered: " + job.sources.compactMap { URL(string: $0.url)?.host }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", "))
        // Each claim with the pages it cites.
        ResearchCitedReport(job: job)
      }
    } else { MessageContent(text: message.text, showsCopyButton: true) }
  }
}
