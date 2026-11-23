import AVKit
import AppKit
import SwiftUI

/// A chat picture or video full size, in a sheet over Serein, so a click never leaves the app.
/// ← and → page through the others it came with; Esc or Done closes it. Copy, Show in Finder and
/// Open in the person's own app stay one click away for when they do want the file. Names are
/// drawn as plain text: they come from projects and are untrusted.
struct PictureViewer: View {
  struct Item: Identifiable, Equatable {
    enum Kind { case image, video }
    let url: URL
    let name: String
    let kind: Kind
    var id: URL { url }
  }

  /// What a click asked to show. Its id stays put while the viewer pages, so the sheet does not
  /// close and open again on every arrow.
  struct Request: Identifiable {
    let id = UUID()
    let items: [Item]
    let start: Int
  }

  let items: [Item]
  let close: () -> Void
  @State private var index: Int
  @Environment(\.palette) private var p

  init(items: [Item], start: Int = 0, close: @escaping () -> Void) {
    self.items = items
    self.close = close
    _index = State(initialValue: min(max(0, start), max(0, items.count - 1)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if items.indices.contains(index) {
        let item = items[index]
        Text(verbatim: item.name).font(UIStyle.bodyStrong).foregroundStyle(p.ink)
          .lineLimit(1).truncationMode(.middle)
        stage(item)
        footer(item)
      }
    }
    .padding(20)
    .frame(width: Self.stage.width + 40, alignment: .topLeading)
    .background(p.panel)
    .onExitCommand(perform: close)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(items.indices.contains(index) ? items[index].name : "Picture")
  }

  /// One size for every item, so paging never resizes the sheet: most of the screen, no larger
  /// than a comfortable reading size.
  static var stage: CGSize {
    let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    return CGSize(width: min(960, (screen.width * 0.72).rounded()), height: min(620, (screen.height * 0.66).rounded()))
  }

  @ViewBuilder private func stage(_ item: Item) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.track)
      switch item.kind {
      case .image:
        if let image = MessageImage.image(item.url) {
          // Fit, never stretched past its own size: a small screenshot stays sharp.
          Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(maxWidth: min(Self.stage.width, image.size.width), maxHeight: min(Self.stage.height, image.size.height))
            .accessibilityLabel(item.name)
        } else {
          Text("This picture was moved or deleted.").font(UIStyle.meta).foregroundStyle(p.secondary)
        }
      case .video:
        ViewerVideo(url: item.url).id(item.url)
      }
    }
    .frame(width: Self.stage.width, height: Self.stage.height)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func footer(_ item: Item) -> some View {
    HStack(spacing: 8) {
      if items.count > 1 {
        Button { page(-1) } label: { InterfaceIcon(systemName: "chevron.left", size: 12).frame(width: 14) }
          .buttonStyle(PillButton(kind: .tinted, small: true))
          .keyboardShortcut(.leftArrow, modifiers: [])
          .disabled(index == 0)
          .help("Previous (←)").accessibilityLabel("Previous")
        Button { page(1) } label: { InterfaceIcon(systemName: "chevron.right", size: 12).frame(width: 14) }
          .buttonStyle(PillButton(kind: .tinted, small: true))
          .keyboardShortcut(.rightArrow, modifiers: [])
          .disabled(index == items.count - 1)
          .help("Next (→)").accessibilityLabel("Next")
        Text(verbatim: "\(index + 1) of \(items.count)").font(UIStyle.meta).foregroundStyle(p.secondary).monospacedDigit()
          .padding(.leading, 4)
      }
      Spacer(minLength: 12)
      if item.kind == .image, let image = MessageImage.image(item.url) {
        Button("Copy") { MessageImage.copy(image, url: item.url) }.buttonStyle(QuietButton())
      }
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.buttonStyle(QuietButton())
      Button("Open in \(Self.appName(for: item.url))") { NSWorkspace.shared.open(item.url) }.buttonStyle(QuietButton())
      Button("Done", action: close).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
    }
  }

  private func page(_ by: Int) {
    let next = index + by
    guard items.indices.contains(next) else { return }
    index = next
  }

  /// The app the file opens in outside Serein ("Preview"), or "App" when none is known.
  static func appName(for url: URL) -> String {
    guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "App" }
    return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
  }
}

/// A video in the viewer: plays as soon as it shows, stops when the viewer pages or closes.
private struct ViewerVideo: View {
  let url: URL
  @State private var player: AVPlayer?
  var body: some View {
    Group {
      if let player { VideoPlayer(player: player) } else { Color.clear }
    }
    .onAppear {
      let next = AVPlayer(url: url)
      player = next
      next.play()
    }
    .onDisappear { player?.pause() }
  }
}
