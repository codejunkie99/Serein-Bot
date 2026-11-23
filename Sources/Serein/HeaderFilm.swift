import AVFoundation
import SwiftUI

/// The sidebar header's film: the Serein logo scene of the showreel (the one setup opens
/// with). It plays one time and then stays on the mark with the name beside it. Reduce Motion
/// shows that frame at once. Reduced effects and UI previews show the daily drawing instead,
/// so captures stay deterministic.
struct SidebarHeaderMedia: View {
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.sereinReducedEffects) var reducedEffects
  /// True when the card shows the film and not the drawing. The film is dark in both
  /// appearances, so what is drawn on the card must be light then.
  static func showsFilm(reducedEffects: Bool) -> Bool {
    // A UI preview draws the still art, so captures do not change from run to run; `--ui-film`
    // shows the film there too.
    let preview = CommandLine.arguments.contains("--ui-preview") && !CommandLine.arguments.contains("--ui-film")
    return !reducedEffects && !preview && HeaderFilm.url != nil
  }
  var body: some View {
    if Self.showsFilm(reducedEffects: reducedEffects), let url = HeaderFilm.url {
      HeaderFilm(url: url, holdAt: HeaderFilm.nameTime, still: reduceMotion)
    } else {
      SidebarHeaderArt()
    }
  }
}

struct HeaderFilm: NSViewRepresentable {
  static let url = Bundle.module.url(
    forResource: "sidebar-header", withExtension: "mp4", subdirectory: "Wallpapers")
  /// Where the sidebar film stays: the mark at the left with "Serein" beside it. The film
  /// holds this picture from about 2.4 to 3.2 seconds.
  static let nameTime = CMTime(seconds: 2.8, preferredTimescale: 600)
  var url: URL
  /// When set, the film plays one time to this point and stays there. Nil is a loop, as in setup.
  var holdAt: CMTime?
  /// Shows the held frame at once, with no motion.
  var still = false
  func makeNSView(context: Context) -> FilmView { FilmView(url: url, holdAt: holdAt, still: still) }
  // Reduce Motion can come on while the film still plays: it goes to the held frame at once.
  func updateNSView(_ view: FilmView, context: Context) { if still { view.settle() } }
  final class FilmView: NSView {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let holdAt: CMTime?
    private var boundary: Any?
    /// True once a film with a hold point is there. It does not play again.
    private var settled = false
    init(url: URL, holdAt: CMTime? = nil, still: Bool = false) {
      self.holdAt = holdAt
      super.init(frame: .zero)
      let layer = AVPlayerLayer(player: player)
      layer.videoGravity = .resizeAspectFill
      self.layer = layer
      wantsLayer = true
      player.isMuted = true
      player.preventsDisplaySleepDuringVideoPlayback = false
      let item = AVPlayerItem(url: url)
      guard let holdAt else {
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
        return
      }
      player.insert(item, after: nil)
      if still {
        settle()
      } else {
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: holdAt)], queue: .main) {
          [weak self] in MainActor.assumeIsolated { self?.settle() }
        }
        player.play()
      }
    }
    /// Stops on the exact frame: the observer can come a frame late.
    func settle() {
      guard let holdAt, !settled else { return }
      settled = true
      player.pause()
      player.seek(to: holdAt, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    required init?(coder: NSCoder) { nil }
    private var occlusion: NSObjectProtocol?
    // Plays only while on screen: a minimized or fully covered window pauses it.
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
      occlusion = window.map { window in
        NotificationCenter.default.addObserver(
          forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
      }
      update()
    }
    private func update() {
      guard !settled else { return }
      if let window, window.occlusionState.contains(.visible) { player.play() } else { player.pause() }
    }
    deinit {
      if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
      if let boundary { player.removeTimeObserver(boundary) }
    }
  }
}
