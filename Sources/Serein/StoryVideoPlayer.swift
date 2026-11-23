import AppKit
import AVKit
import SwiftUI

/// Keep transport controls visible in a scrolling chat, where AVKit's hover panel is
/// difficult to reach. The inline and full-screen surfaces share one real player.
struct StoryVideoPlayer: View {
  let player: AVPlayer
  let title: String
  var closeFullScreen: (() -> Void)? = nil
  @Environment(\.palette) private var p
  @State private var elapsed = 0.0
  @State private var duration = 0.0
  @State private var playing = false
  @State private var muted = false
  @State private var observer: Any?
  @State private var statusObserver: NSKeyValueObservation?
  @State private var muteObserver: NSKeyValueObservation?
  @State private var fullScreenWindow: NSWindow?

  var body: some View {
    VStack(spacing: 8) {
      StoryVideoSurface(player: player).aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(title)
      HStack(spacing: 10) {
        Button {
          if playing { player.pause() }
          else {
            if duration > 0, elapsed >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
          }
          refresh()
        } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 14) }
          .buttonStyle(QuietButton()).accessibilityLabel(playing ? "Pause video" : "Play video")
          .help(playing ? "Pause video" : "Play video")
        Slider(value: Binding(get: { min(elapsed, max(duration, 1)) }, set: { value in
          elapsed = value
          player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }), in: 0...max(duration, 1))
          .disabled(duration <= 0).tint(p.ink)
          .accessibilityLabel("Video position")
          .accessibilityValue("\(timestamp(elapsed)) of \(timestamp(duration))")
        Text("\(timestamp(elapsed)) / \(timestamp(duration))")
          .monospacedDigit().fixedSize().foregroundStyle(p.secondary)
        Button { player.isMuted.toggle(); refresh() } label: {
          Image(systemName: muted ? "speaker.slash" : "speaker.wave.2")
        }.buttonStyle(QuietButton()).accessibilityLabel(muted ? "Unmute narration" : "Mute narration")
          .help(muted ? "Unmute narration" : "Mute narration")
        Button {
          if let closeFullScreen { closeFullScreen() } else { openFullScreen() }
        } label: { Image(systemName: closeFullScreen == nil ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") }
          .buttonStyle(QuietButton()).accessibilityLabel(closeFullScreen == nil ? "Full screen" : "Back to chat")
          .help(closeFullScreen == nil ? "Full screen" : "Back to chat")
      }.font(AssistantType.meta).foregroundStyle(p.ink)
    }
    .onAppear {
      refresh()
      guard observer == nil else { return }
      statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { _, _ in
        Task { @MainActor in refresh() }
      }
      muteObserver = player.observe(\.isMuted, options: [.initial, .new]) { _, _ in
        Task { @MainActor in refresh() }
      }
      observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { _ in
        MainActor.assumeIsolated { refresh() }
      }
    }
    .task(id: ObjectIdentifier(player)) {
      guard let asset = player.currentItem?.asset,
        let length = try? await asset.load(.duration).seconds,
        length.isFinite, length > 0, !Task.isCancelled else { return }
      duration = length
    }
    .onDisappear {
      if let observer { player.removeTimeObserver(observer); self.observer = nil }
      statusObserver?.invalidate(); statusObserver = nil
      muteObserver?.invalidate(); muteObserver = nil
      player.pause()
      fullScreenWindow?.close(); fullScreenWindow = nil
    }
  }

  private func refresh() {
    let time = player.currentTime().seconds
    let length = player.currentItem?.duration.seconds ?? 0
    elapsed = time.isFinite ? max(0, time) : 0
    if length.isFinite, length > 0 { duration = length }
    playing = player.timeControlStatus != .paused
    muted = player.isMuted
  }

  private func timestamp(_ seconds: Double) -> String {
    let seconds = Int(seconds)
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
  }

  private func openFullScreen() {
    if let window = fullScreenWindow, window.isVisible { window.makeKeyAndOrderFront(nil); return }
    let window = StoryVideoWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 630),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenPrimary]
    window.videoPlayer = player
    window.contentView = NSHostingView(rootView:
      StoryVideoPlayer(player: player, title: title, closeFullScreen: { [weak window] in window?.close() })
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.background).environment(\.palette, p))
    fullScreenWindow = window
    window.center(); window.makeKeyAndOrderFront(nil); window.toggleFullScreen(nil)
  }
}

private final class StoryVideoWindow: NSWindow {
  weak var videoPlayer: AVPlayer?
  override func close() {
    videoPlayer?.pause()
    super.close()
    contentView = nil
  }
  override func cancelOperation(_ sender: Any?) { close() }
}

private struct StoryVideoSurface: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .none
    view.allowsVideoFrameAnalysis = false
    view.videoGravity = .resizeAspect
    view.player = player
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
