import AVFoundation
import AVKit
import SereinCore
import SwiftUI

/// A report's reel in the chat (`ReportReel`): a header with the title, its one-line summary and
/// Listen; the added and removed lines, the test result and the time worked as figures; the
/// biggest files as green and red bars; and what the session made, as a grid: pictures and videos
/// open in Serein's viewer, sounds play in a pill. Every word is drawn as plain text: file
/// names come from the project and are untrusted.
struct ReportReelCard: View {
  let reel: ReportReel
  /// Reads the reel aloud; nil hides Listen.
  var speak: ((String) -> Void)? = nil
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  @State private var shown = false
  @State private var viewing: PictureViewer.Request?
  private var reduce: Bool { systemReduceMotion || previewReducedEffects }

  var body: some View {
    if !reel.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        header
        if reel.filesTotal > 0 || reel.tests != nil || (reel.minutes ?? 0) > 0 { figures }
        if !reel.files.isEmpty { bars }
        if !reel.media.isEmpty { strip }
      }
      .padding(14)
      .frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading)
      .assistantCard(p)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(reel.title): \(reel.summary)")
      .onAppear { if reduce { shown = true } else { withAnimation(Motion.enter) { shown = true } } }
    }
  }

  /// The app the title names ("Claude Code in serein agent"), the longest name that fits.
  private var provider: Provider? {
    guard reel.sessions == nil else { return nil }
    return Provider.allCases
      .compactMap { provider in provider.driver.map { (provider, $0.displayName) } }
      .filter { reel.title.hasPrefix($0.1 + " ") }
      .max { $0.1.count < $1.1.count }?.0
  }

  private var header: some View {
    HStack(spacing: 10) {
      // The app that did the work, by its own logo; a summary of several sessions has none.
      if let provider { ModelMonogram(provider: provider, size: 22) }
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: reel.title).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
        if let projects = reel.projects, !projects.isEmpty {
          Text(verbatim: projects.prefix(3).joined(separator: " · ") + (projects.count > 3 ? " +\(projects.count - 3)" : ""))
            .font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if let speak {
        Button { speak(reel.narration) } label: {
          HStack(spacing: 5) {
            InterfaceIcon(systemName: "speaker.wave.2", size: 11)
            Text("Listen").font(AssistantType.meta)
          }
          .foregroundStyle(p.ink).padding(.horizontal, 10).frame(minHeight: 26)
          .background(p.track, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(AssistantPressStyle())
        .help("Read this aloud")
        .accessibilityLabel("Listen to \(reel.title)")
      }
    }
  }

  private var figures: some View {
    HStack(spacing: 8) {
      if reel.filesTotal > 0 {
        figure("+\(reel.added)", tint: p.success)
        figure("−\(reel.removed)", tint: p.danger)
        figure(reel.filesTotal == 1 ? "1 file" : "\(reel.filesTotal) files", tint: p.secondary)
      }
      if let tests = reel.tests {
        HStack(spacing: 4) {
          InterfaceIcon(systemName: tests == .passed ? "checkmark" : "xmark", size: 10)
          Text(tests == .passed ? "Tests passed" : "Tests failed").font(AssistantType.meta)
        }
        .foregroundStyle(tests == .passed ? p.success : p.danger)
        .padding(.horizontal, 8).frame(minHeight: 22)
        .background((tests == .passed ? p.success : p.danger).opacity(0.12), in: Capsule())
      }
      if let minutes = reel.minutes, minutes > 0 { figure(ReportReel.duration(minutes), tint: p.secondary) }
    }
  }

  private func figure(_ text: String, tint: Color) -> some View {
    Text(verbatim: text).font(AssistantType.figures).foregroundStyle(tint).lineLimit(1)
  }

  /// One row per big file: its path, then green for added and red for removed, as long as its
  /// share of the biggest file's change.
  private var bars: some View {
    let biggest = max(1, reel.files.map(\.churn).max() ?? 1)
    return VStack(alignment: .leading, spacing: 6) {
      ForEach(reel.files, id: \.path) { file in
        HStack(spacing: 10) {
          Text(verbatim: file.path).font(AssistantType.figures).foregroundStyle(p.ink)
            .lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
          GeometryReader { box in
            let whole = box.size.width * CGFloat(file.churn) / CGFloat(biggest)
            let green = file.churn == 0 ? 0 : whole * CGFloat(file.added) / CGFloat(file.churn)
            HStack(spacing: 1) {
              Capsule().fill(p.success).frame(width: max(file.added > 0 ? 2 : 0, green))
              Capsule().fill(p.danger).frame(width: max(file.removed > 0 ? 2 : 0, whole - green))
            }
            .frame(height: 6).frame(maxHeight: .infinity)
            // Grows in from the left once: a transform, so no layout moves.
            .scaleEffect(x: shown ? 1 : 0.02, y: 1, anchor: .leading)
          }
          .frame(height: 14)
          Text(verbatim: "+\(file.added) −\(file.removed)").font(AssistantType.figures).foregroundStyle(p.secondary)
            .lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.path): \(file.added) added, \(file.removed) removed")
      }
    }
  }

  /// Everything the session made, without a sideways scroll (a mouse wheel cannot move one):
  /// pictures and videos as a grid (`columns`), at most `maxTiles`; past that the last tile says
  /// how many more ("+5") and opens the viewer there. Sounds are pills under it. A click on any
  /// tile opens the viewer, which pages through every one.
  private var strip: some View {
    let all = visuals
    let tiles = Array(all.prefix(Self.maxTiles))
    let sounds = reel.media.filter { $0.kind == .audio }
    let items = all.map { PictureViewer.Item(url: $0.url, name: $0.media.name, kind: $0.media.kind == .video ? .video : .image) }
    return VStack(alignment: .leading, spacing: 8) {
      if !tiles.isEmpty {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: Self.columns(tiles.count)), spacing: 8) {
          ForEach(Array(tiles.enumerated()), id: \.element.media.id) { index, visual in
            let last = index == tiles.count - 1 && all.count > tiles.count
            ReelTile(media: visual.media, url: visual.url, wide: tiles.count == 1, more: last ? all.count - index : nil) {
              viewing = PictureViewer.Request(items: items, start: index)
            }
          }
        }
      }
      if !sounds.isEmpty {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(sounds.count, 2)), spacing: 8) {
          ForEach(sounds) { ReelSound(media: $0) }
        }
      }
    }
    .sheet(item: $viewing) { request in
      PictureViewer(items: request.items, start: request.start) { viewing = nil }.environment(\.palette, p)
    }
    // `--ui-reel-viewer` (with `--ui-session-report-reel media`): the viewer open on the second.
    .onAppear {
      if Self.previewViewer, items.count > 1 { viewing = PictureViewer.Request(items: items, start: 1) }
    }
  }

  private static let previewViewer = CommandLine.arguments.contains("--ui-preview")
    && CommandLine.arguments.contains("--ui-reel-viewer")

  /// The most tiles a card draws, so a busy session keeps the card one size.
  static let maxTiles = 4
  /// Columns for `count` tiles, so no row is left with one: 1, 2, 3 across; four as two by two.
  static func columns(_ count: Int) -> Int { count == 4 ? 2 : min(max(count, 1), 3) }

  /// The pictures and videos whose copies are still in the library, in the reel's order.
  private var visuals: [(media: ReportReel.Media, url: URL)] {
    reel.media.compactMap { media in
      guard media.kind != .audio, let url = ReelMediaFile.url(media.path) else { return nil }
      return (media, url)
    }
  }
}

/// The library file a reel's media names, or nil: only copies in chat-images, as the chat's
/// pictures (`MessageImage.file`), with symlinks resolved, so a reel cannot show other files.
enum ReelMediaFile {
  @MainActor static func url(_ path: String) -> URL? {
    guard let library = BrowserContext.browser?.library.root ?? SereinRouter.browser?.library.root,
      path.hasPrefix("chat-images/"), !path.contains("..")
    else { return nil }
    func real(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    let url = URL(fileURLWithPath: real(library.appendingPathComponent(path)))
    guard url.path.hasPrefix(real(library.appendingPathComponent("chat-images")) + "/"),
      FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return url
  }
}

/// One picture or video in the grid: cropped to fill its tile, its name at the foot, a play mark
/// on a video, and an expand mark on hover. A click opens the viewer. The last tile of a full grid
/// is dimmed under "+N", the pictures it stands for (itself and those after it).
private struct ReelTile: View {
  let media: ReportReel.Media
  let url: URL
  /// The only one: the card's full width, wider than tall.
  let wide: Bool
  /// How many this tile stands for when the grid is full; nil for a plain tile.
  var more: Int? = nil
  let open: () -> Void
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  @State private var poster: NSImage?
  @State private var hovered = false
  private var isVideo: Bool { media.kind == .video }
  var body: some View {
    Button(action: open) {
      Rectangle().fill(p.track)
        .aspectRatio(wide ? 16 / 9 : 4 / 3, contentMode: .fit)
        .overlay {
          if let picture = isVideo ? poster : MessageImage.image(url) {
            Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
          }
        }
        .overlay {
          if let more {
            Rectangle().fill(.black.opacity(hovered ? 0.5 : 0.6))
            Text(verbatim: "+\(more)").font(UIStyle.font(22, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
          } else if isVideo {
            InterfaceIcon(systemName: "play.fill", size: 14).foregroundStyle(.white)
              .frame(width: 34, height: 34).background(.black.opacity(0.55), in: Circle())
          }
        }
        .overlay(alignment: .topTrailing) {
          if more == nil {
            InterfaceIcon(systemName: "arrow.up.left.and.arrow.down.right", size: 10).foregroundStyle(.white)
              .frame(width: 22, height: 22).background(.black.opacity(0.55), in: Circle())
              .padding(6).opacity(hovered ? 1 : 0)
          }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(hovered ? p.secondary.opacity(0.6) : p.line))
        .overlay(alignment: .bottomLeading) { if more == nil { ReelCaption(text: media.name) } }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(AssistantPressStyle())
    .onHover { hovered = $0 }
    .animation(systemReduceMotion || previewReducedEffects ? nil : .easeOut(duration: 0.12), value: hovered)
    .help(more.map { "View \($0) more" } ?? (isVideo ? "Play \(media.name)" : "View \(media.name)"))
    .accessibilityLabel(more.map { "View \($0) more" } ?? ((isVideo ? "Play video " : "View picture ") + media.name))
    .task(id: url) { if isVideo { poster = await Self.frame(url) } }
  }

  private static func frame(_ url: URL) async -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 440, height: 248)
    guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
    return NSImage(cgImage: image, size: .zero)
  }
}

/// A sound as a pill: play or pause, its name and its length.
private struct ReelSound: View {
  let media: ReportReel.Media
  @Environment(\.palette) private var p
  @State private var player: AVPlayer?
  @State private var playing = false
  @State private var length: String = ""
  var body: some View {
    if let url = ReelMediaFile.url(media.path) {
      Button { toggle(url) } label: {
        HStack(spacing: 8) {
          InterfaceIcon(systemName: playing ? "pause.fill" : "play.fill", size: 11).foregroundStyle(p.onSolid)
            .frame(width: 26, height: 26).background(p.solid, in: Circle())
          VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: media.name).font(AssistantType.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
            if !length.isEmpty { Text(verbatim: length).font(AssistantType.figures).foregroundStyle(p.secondary) }
          }
        }
        .padding(.leading, 6).padding(.trailing, 12).frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        .background(p.track, in: Capsule()).contentShape(Capsule())
      }
      .buttonStyle(AssistantPressStyle())
      .help(playing ? "Pause" : "Play \(media.name)")
      .accessibilityLabel((playing ? "Pause " : "Play ") + media.name)
      .task(id: url) {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite else { return }
        length = String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
      }
      .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
        guard let item = note.object as? AVPlayerItem, item == player?.currentItem else { return }
        playing = false
        player?.seek(to: .zero)
      }
      .onDisappear { player?.pause(); playing = false }
    }
  }

  private func toggle(_ url: URL) {
    let current = player ?? AVPlayer(url: url)
    player = current
    if playing { current.pause() } else { current.play() }
    playing.toggle()
  }
}

/// A file's name on a dark wash at the foot of a picture or video.
private struct ReelCaption: View {
  let text: String
  var body: some View {
    Text(verbatim: text).font(UIStyle.font(10)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
      .padding(.horizontal, 6).padding(.vertical, 3)
      .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .padding(6)
  }
}
