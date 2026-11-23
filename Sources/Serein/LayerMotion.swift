import AppKit
import QuartzCore
import SwiftUI

// Motion that Core Animation runs by itself: Serein sets each layer up once and does no work for
// the frames that follow. SwiftUI would drive every frame from the main thread, a repeating
// `.animation` as much as a TimelineView: about a third of a core for as long as an agent works.

/// An arc of a ring that turns clockwise, centred in the view. By default `ActivityRing`'s: a
/// 12-point ring, 0.3 of it drawn 2 points wide with round ends, 270° a second. The view leaves
/// room around the ring for the stroke's outer half.
struct TurningArc: NSViewRepresentable {
  var color: Color
  /// The ring's own size, not the view's: SwiftUI rounds a view's frame to whole pixels.
  var diameter: CGFloat = 12
  /// How much of the ring the arc covers.
  var fraction: CGFloat = 0.3
  var lineWidth: CGFloat = 2
  var lineCap: CGLineCap = .round
  /// Seconds for one turn.
  var period: TimeInterval = 4.0 / 3.0
  private var style: ArcView.Style {
    ArcView.Style(
      diameter: diameter, fraction: fraction, lineWidth: lineWidth, lineCap: lineCap, period: period)
  }
  func makeNSView(context: Context) -> ArcView { ArcView(style: style) }
  func updateNSView(_ view: ArcView, context: Context) {
    view.color = color.resolve(in: context.environment).cgColor
    view.style = style
  }
  final class ArcView: MotionLayerView {
    struct Style: Equatable {
      var diameter: CGFloat
      var fraction: CGFloat
      var lineWidth: CGFloat
      var lineCap: CGLineCap
      var period: TimeInterval
    }
    private let arc = CAShapeLayer()
    var color: CGColor? { didSet { instantly { arc.strokeColor = color } } }
    var style: Style { didSet { if style != oldValue { needsLayout = true } } }
    init(style: Style) {
      self.style = style
      super.init(frame: .zero)
      arc.fillColor = nil
      layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { nil }
    override func restart() {
      instantly {
        arc.contentsScale = window?.backingScaleFactor ?? 2
        arc.bounds = bounds
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        arc.lineWidth = style.lineWidth
        arc.lineCap = style.lineCap == .round ? .round : style.lineCap == .square ? .square : .butt
        arc.strokeEnd = style.fraction
        let ring = CGRect(
          x: bounds.midX - style.diameter / 2, y: bounds.midY - style.diameter / 2,
          width: style.diameter, height: style.diameter)
        arc.path = CGPath(ellipseIn: ring, transform: nil)
      }
      let turn = CABasicAnimation(keyPath: "transform.rotation.z")
      turn.fromValue = 0
      turn.toValue = 2 * Double.pi
      arc.addInStep(turn, period: style.period, forKey: "turn")
    }
  }
}

/// The highlight down a working agent's status bar: 0.7 of the bar tall, from just above its
/// top to just below its bottom every 1.4 seconds, clipped to the bar's capsule.
struct ShimmerSweep: NSViewRepresentable {
  var color: Color
  func makeNSView(context: Context) -> SweepView { SweepView() }
  func updateNSView(_ view: SweepView, context: Context) {
    view.color = color.resolve(in: context.environment).cgColor
  }
  final class SweepView: MotionLayerView {
    private let band = CAGradientLayer()
    var color: CGColor? {
      didSet {
        guard let color, let clear = color.copy(alpha: 0) else { return }
        // Fades to the same colour, as SwiftUI's gradient from .clear does; clear black would
        // grey the band's edges.
        instantly { band.colors = [clear, color, clear] }
      }
    }
    override init(frame: NSRect) {
      super.init(frame: frame)
      layer?.masksToBounds = true
      layer?.addSublayer(band)
    }
    required init?(coder: NSCoder) { nil }
    override func restart() {
      let height = bounds.height
      instantly {
        layer?.cornerRadius = min(bounds.width, height) / 2
        band.contentsScale = window?.backingScaleFactor ?? 2
        band.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: height * 0.7)
        band.position = CGPoint(x: bounds.midX, y: -height * 0.35)
      }
      let sweep = CABasicAnimation(keyPath: "position.y")
      sweep.fromValue = -height * 0.35
      sweep.toValue = height * 1.35
      band.addInStep(sweep, period: 1.4, forKey: "sweep")
    }
  }
}

/// `LinkedWorkingRow`'s harness mark while the other app works: it fades to 0.35 and shrinks to
/// 0.86 of its size and back, 1.1 seconds each way, eased at both ends. SwiftUI draws the content
/// once, in a hosting view of its own, and Core Animation fades and scales that view's layer.
struct Breathing<Content: View>: NSViewRepresentable {
  var content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  func makeNSView(context: Context) -> BreathView { BreathView(content) }
  func updateNSView(_ view: BreathView, context: Context) { view.host.rootView = content }
  final class BreathView: MotionLayerView {
    let host: NSHostingView<Content>
    init(_ content: Content) {
      host = NSHostingView(rootView: content)
      super.init(frame: .zero)
      // As large as this view, whatever size the content would take.
      host.sizingOptions = []
      host.wantsLayer = true
      addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    override func restart() {
      host.frame = bounds
      guard let layer = host.layer else { return }
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1.0
      fade.toValue = 0.35
      // About the middle: AppKit anchors a view's layer at a corner.
      let x = bounds.width * (0.5 - layer.anchorPoint.x), y = bounds.height * (0.5 - layer.anchorPoint.y)
      let shrink = CABasicAnimation(keyPath: "transform")
      shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
      shrink.toValue = NSValue(caTransform3D: CATransform3DTranslate(
        CATransform3DScale(CATransform3DMakeTranslation(x, y, 0), 0.86, 0.86, 1), -x, -y, 0))
      for (key, animation) in [("fade", fade), ("shrink", shrink)] {
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.autoreverses = true
        layer.addInStep(animation, period: 2.2, forKey: key)
      }
    }
  }
}

/// A working assistant's petal (`SereinMark`'s five orbits and its core) turning about its middle
/// once every `period` seconds. Core Animation turns it, so SwiftUI does nothing per frame.
struct TurningPetal: NSViewRepresentable {
  var color: Color
  var size: CGFloat
  var period: TimeInterval = 6
  func makeNSView(context: Context) -> PetalView { PetalView() }
  func updateNSView(_ view: PetalView, context: Context) {
    view.color = color.resolve(in: context.environment).cgColor
    view.style = PetalView.Style(size: size, period: period)
  }
  final class PetalView: ShownMotionView {
    struct Style: Equatable {
      var size: CGFloat
      var period: TimeInterval
    }
    private let petals = CAShapeLayer()
    private let core = CAShapeLayer()
    var color: CGColor? {
      didSet {
        instantly {
          petals.strokeColor = color
          core.fillColor = color
        }
      }
    }
    var style = Style(size: 16, period: 6) { didSet { if style != oldValue { needsLayout = true } } }
    override init(frame: NSRect) {
      super.init(frame: frame)
      petals.fillColor = nil
      petals.lineWidth = 1.3
      layer?.addSublayer(petals)
      layer?.addSublayer(core)
    }
    required init?(coder: NSCoder) { nil }
    override func layOut() {
      let size = style.size
      instantly {
        let scale = window?.backingScaleFactor ?? 2
        petals.contentsScale = scale
        core.contentsScale = scale
        petals.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        petals.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // SereinMark's geometry: five ellipses 0.4 by 0.86 of the side, 36° apart.
        let orbit = CGRect(x: -size * 0.2, y: -size * 0.43, width: size * 0.4, height: size * 0.86)
        let path = CGMutablePath()
        for i in 0..<5 {
          path.addEllipse(in: orbit, transform: CGAffineTransform(translationX: size / 2, y: size / 2).rotated(by: CGFloat(i) * .pi / 5))
        }
        petals.path = path
        core.frame = bounds
        core.path = CGPath(ellipseIn: CGRect(x: bounds.midX - 2, y: bounds.midY - 2, width: 4, height: 4), transform: nil)
      }
    }
    override func loop() {
      let turn = CABasicAnimation(keyPath: "transform.rotation.z")
      turn.fromValue = 0
      turn.toValue = 2 * Double.pi
      petals.addInStep(turn, period: style.period, forKey: "turn")
    }
  }
}

/// A ring at a mark's edge whose opacity eases down to a quarter and back every `period` seconds:
/// a working mark's tint ring with a soft glow, or Needs you's amber ring.
struct PulsingRing: NSViewRepresentable {
  var color: Color
  var lineWidth: CGFloat
  var period: TimeInterval
  /// A soft halo of the same colour around the ring.
  var glow = false
  func makeNSView(context: Context) -> RingView { RingView() }
  func updateNSView(_ view: RingView, context: Context) {
    view.color = color.resolve(in: context.environment).cgColor
    view.style = RingView.Style(lineWidth: lineWidth, period: period, glow: glow)
  }
  final class RingView: ShownMotionView {
    struct Style: Equatable {
      var lineWidth: CGFloat
      var period: TimeInterval
      var glow: Bool
    }
    private let ring = CAShapeLayer()
    var color: CGColor? {
      didSet {
        instantly {
          ring.strokeColor = color
          ring.shadowColor = color
        }
      }
    }
    var style = Style(lineWidth: 1, period: 1.6, glow: false) { didSet { if style != oldValue { needsLayout = true } } }
    override init(frame: NSRect) {
      super.init(frame: frame)
      ring.fillColor = nil
      ring.shadowOffset = .zero
      layer?.addSublayer(ring)
    }
    required init?(coder: NSCoder) { nil }
    override func layOut() {
      instantly {
        ring.contentsScale = window?.backingScaleFactor ?? 2
        ring.frame = bounds
        ring.lineWidth = style.lineWidth
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: style.lineWidth / 2, dy: style.lineWidth / 2), transform: nil)
        ring.shadowRadius = style.glow ? max(1.5, bounds.width * 0.08) : 0
        ring.shadowOpacity = style.glow ? 0.9 : 0
      }
    }
    override func loop() {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1.0
      fade.toValue = 0.25
      fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      fade.autoreverses = true
      ring.addInStep(fade, period: style.period, forKey: "pulse")
    }
  }
}

/// Three dots that brighten one after another every 1.2 seconds, after a speaker's mark while its
/// reply streams in.
struct TypingDots: NSViewRepresentable {
  var color: Color
  func makeNSView(context: Context) -> DotsView { DotsView() }
  func updateNSView(_ view: DotsView, context: Context) {
    view.color = color.resolve(in: context.environment).cgColor
  }
  final class DotsView: ShownMotionView {
    private let dots = (0..<3).map { _ in CAShapeLayer() }
    var color: CGColor? { didSet { instantly { dots.forEach { $0.fillColor = color } } } }
    override init(frame: NSRect) {
      super.init(frame: frame)
      dots.forEach { layer?.addSublayer($0) }
    }
    required init?(coder: NSCoder) { nil }
    override func layOut() {
      // Three dots across the width, each a fifth of it (at most the height), centred.
      let side = min(bounds.height, bounds.width / 5)
      instantly {
        for (i, dot) in dots.enumerated() {
          dot.contentsScale = window?.backingScaleFactor ?? 2
          dot.frame = bounds
          let x = bounds.width * CGFloat(2 * i + 1) / 6 - side / 2
          dot.path = CGPath(ellipseIn: CGRect(x: x, y: bounds.midY - side / 2, width: side, height: side), transform: nil)
        }
      }
    }
    override func loop() {
      for (i, dot) in dots.enumerated() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.25
        fade.toValue = 1.0
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.autoreverses = true
        // Each dot 0.2 seconds behind the one before it.
        dot.addInStep(fade, period: 1.2, ahead: 1.2 - Double(i) * 0.2, forKey: "type")
      }
    }
  }
}

/// A `MotionLayerView` that loops only while it shows: in a window that is on screen and not
/// covered, and not scrolled out of its scroll view; otherwise its layers hold still. Subclasses
/// lay their layers out in `layOut` and add the loop in `loop`.
class ShownMotionView: MotionLayerView {
  private var occlusion: NSObjectProtocol?
  private var scrolling: NSObjectProtocol?
  private var looping = false
  override func viewDidMoveToWindow() {
    for observer in [occlusion, scrolling].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    occlusion = window.map { window in
      NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.restart() } }
    }
    // A row scrolled out of sight stops; one scrolled back starts again.
    scrolling = nil
    if window != nil, let clip = enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      scrolling = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.scrolled() } }
    }
    super.viewDidMoveToWindow()
  }
  deinit {
    for observer in [occlusion, scrolling].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
  }
  private var shown: Bool { window?.occlusionState.contains(.visible) == true && !visibleRect.isEmpty }
  /// Each scroll step only checks whether it came into or went out of sight.
  private func scrolled() {
    if shown != looping { restart() }
  }
  override func restart() {
    guard !bounds.isEmpty else { return }
    layOut()
    looping = shown
    if looping {
      loop()
    } else {
      layer?.sublayers?.forEach { $0.removeAllAnimations() }
    }
  }
  func layOut() {}
  func loop() {}
}

/// The view under each animated layer: it takes no clicks (the view around it does) and sets
/// its layers up again whenever it comes into a window, changes size or changes screen scale.
class MotionLayerView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }
  required init?(coder: NSCoder) { nil }
  /// Top-left origin, as in SwiftUI: y runs down and positive angles turn clockwise.
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    restartIfShown()
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    restartIfShown()
  }
  override func layout() {
    super.layout()
    restartIfShown()
  }
  private func restartIfShown() {
    if window != nil && !bounds.isEmpty { restart() }
  }
  /// Lays the layers out for the current bounds and adds the animation again.
  func restart() {}
  /// Changes the layers at once, without Core Animation's implicit quarter-second fade.
  func instantly(_ change: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    change()
    CATransaction.commit()
  }
}

private extension CALayer {
  /// Repeats `animation` every `period` seconds, forever, on Core Animation's clock: every layer
  /// running it is at the same point at the same moment, so copies on screen together move in
  /// step. One that autoreverses goes there and back within the period. `ahead` runs this copy
  /// that many seconds ahead of the others (the typing dots, one after another).
  func addInStep(_ animation: CABasicAnimation, period: CFTimeInterval, ahead: CFTimeInterval = 0, forKey key: String) {
    let now = CACurrentMediaTime()
    animation.duration = animation.autoreverses ? period / 2 : period
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    // 30 frames a second, as the at-work ring and the status bar always had: smooth at these
    // sizes, and a fast display need not run at full rate for as long as an agent works.
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    animation.beginTime = convertTime(now, from: nil) - now.truncatingRemainder(dividingBy: period) - ahead
    add(animation, forKey: key)
  }
}
