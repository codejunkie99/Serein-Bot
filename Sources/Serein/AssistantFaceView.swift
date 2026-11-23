import AppKit
import QuartzCore
import SereinCore
import SwiftUI

// An assistant's face (`AssistantFace`, SereinCore): one of five outlines filled in the assistant's
// tint, and two eyes. `AssistantMark` draws it for every assistant that has no icon of its own;
// a chosen `AssistantIcon` still wins, and Serein (the main assistant) keeps its app icon.

/// The faces by assistant id. SHA-256 of the id gives the shape and the first tint; the row's own
/// colour (`RelayProfile.colour`) then wins, so the face and the row agree.
enum AssistantFaces {
  private static var cache: [String: AssistantFace] = [:]
  static func face(for id: String, wearing colour: String?) -> AssistantFace {
    if let known = cache[id] { return known.wearing(colour) }
    let made = AssistantFace(id: id)
    if cache.count >= 256 { cache.removeAll() }
    cache[id] = made
    return made.wearing(colour)
  }
}

/// The face's geometry in points, from the face's 24-point box (`AssistantFace.box`). SwiftUI and
/// Core Animation draw from the same paths, so a still face and a moving one look the same.
enum FaceGeometry {
  /// The board's eye in the box: 2.5 wide and 3.2 tall (Nb*.dc.html).
  static let eyeWidth: CGFloat = 2.5
  static let eyeHeight: CGFloat = 3.2

  static func scale(_ side: CGFloat) -> CGFloat { side / CGFloat(AssistantFace.box) }
  static func point(_ point: AssistantFace.Point, _ scale: CGFloat) -> CGPoint {
    CGPoint(x: CGFloat(point.x) * scale, y: CGFloat(point.y) * scale)
  }
  /// The outline at `side` points, y down.
  static func outline(_ face: AssistantFace, side: CGFloat) -> CGPath {
    let k: CGFloat = scale(side)
    let path = CGMutablePath()
    for step in face.outline {
      switch step {
      case .move(let to): path.move(to: point(to, k))
      case .line(let to): path.addLine(to: point(to, k))
      case .curve(let to, let first, let second):
        path.addCurve(to: point(to, k), control1: point(first, k), control2: point(second, k))
      case .close: path.closeSubpath()
      }
    }
    return path
  }
  static func eye(_ centre: AssistantFace.Point, side: CGFloat, squash: CGFloat = 1) -> CGRect {
    let k: CGFloat = scale(side)
    let width: CGFloat = eyeWidth * k
    let height: CGFloat = max(0.5, eyeHeight * k * squash)
    let middle: CGPoint = point(centre, k)
    return CGRect(x: middle.x - width / 2, y: middle.y - height / 2, width: width, height: height)
  }
  /// The band across both eyes that a blink squashes, twice an eye's height.
  static func eyeBand(_ face: AssistantFace, side: CGFloat) -> CGRect {
    let left: CGRect = eye(face.eyes.left, side: side)
    let band: CGFloat = left.height * 2
    return CGRect(x: 0, y: left.midY - band / 2, width: side, height: band)
  }
  /// Both eyes, drawn from `origin` (the eye band's corner for a moving face, else the box's);
  /// `squash` below 1 closes them (a blink, or a new assistant's face before its first letter).
  static func eyes(_ face: AssistantFace, side: CGFloat, origin: CGPoint = .zero, squash: CGFloat = 1) -> Path {
    var path = Path()
    path.addEllipse(in: eye(face.eyes.left, side: side, squash: squash).offsetBy(dx: -origin.x, dy: -origin.y))
    path.addEllipse(in: eye(face.eyes.right, side: side, squash: squash).offsetBy(dx: -origin.x, dy: -origin.y))
    return path
  }
  /// How long a blink waits, seeded per face: 3.5 to 5 seconds (SPEC.md 10.3), so faces on
  /// screen together do not blink in step.
  static func blinkPeriod(_ face: AssistantFace) -> CFTimeInterval {
    let blobs: [AssistantFace.Blob] = AssistantFace.Blob.allCases
    let shape: Int = blobs.firstIndex(of: face.blob) ?? 0
    let tint: Int = AssistantFace.tints.firstIndex(of: face.tint) ?? 0
    let step: Int = (shape * 7 + tint * 3) % 16
    return 3.5 + CFTimeInterval(step) / 10
  }
}

/// A face at `size` points. Still by default. While the assistant works, the eyes blink about
/// every 4 seconds and the face lifts 1 point on a 1.2-second loop: Core Animation runs both, so
/// SwiftUI draws nothing per frame, and both stop while the face is out of sight. Under Reduce
/// Motion the face stays still.
struct AssistantFaceView: View {
  let face: AssistantFace
  var size: CGFloat
  var working = false
  /// The eyes closed: a new assistant's face before its name has a letter.
  var closedEyes = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let tint: Color = p.assistantTint(face.tint)
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    Group {
      if working && !reduce && !closedEyes {
        MovingFace(face: face, size: size, tint: tint, eye: p.faceEye)
      } else {
        StillFace(face: face, size: size, tint: tint, eye: p.faceEye, squash: closedEyes ? 0.15 : 1)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private struct FaceOutline: View {
  let face: AssistantFace
  let size: CGFloat
  let tint: Color
  var body: some View {
    Path(FaceGeometry.outline(face, side: size)).fill(tint).frame(width: size, height: size)
  }
}

private struct FaceEyes: View {
  let face: AssistantFace
  let size: CGFloat
  let eye: Color
  var origin: CGPoint = .zero
  var squash: CGFloat = 1
  var body: some View {
    FaceGeometry.eyes(face, side: size, origin: origin, squash: squash).fill(eye)
  }
}

private struct StillFace: View {
  let face: AssistantFace
  let size: CGFloat
  let tint: Color
  let eye: Color
  var squash: CGFloat = 1
  var body: some View {
    ZStack(alignment: .topLeading) {
      FaceOutline(face: face, size: size, tint: tint)
      FaceEyes(face: face, size: size, eye: eye, squash: squash).frame(width: size, height: size)
    }.frame(width: size, height: size)
  }
}

/// A working face: SwiftUI draws the outline and the eyes once, each in a hosting view of its own,
/// and Core Animation moves those views' layers.
private struct MovingFace: NSViewRepresentable {
  let face: AssistantFace
  let size: CGFloat
  let tint: Color
  let eye: Color
  private var band: CGRect { FaceGeometry.eyeBand(face, side: size) }
  private var outline: AnyView { AnyView(FaceOutline(face: face, size: size, tint: tint)) }
  private var eyes: AnyView {
    let band: CGRect = self.band
    return AnyView(FaceEyes(face: face, size: size, eye: eye, origin: band.origin).frame(width: band.width, height: band.height))
  }
  func makeNSView(context: Context) -> MovingFaceView {
    MovingFaceView(outline: outline, eyes: eyes, band: band, blinkPeriod: FaceGeometry.blinkPeriod(face))
  }
  func updateNSView(_ view: MovingFaceView, context: Context) {
    view.update(outline: outline, eyes: eyes, band: band)
  }
}

/// The moving face's views: a lifting view that holds the outline and the eye band. The whole
/// face lifts 1 point and back every 1.2 seconds; the eye band squashes to 10% for 0.12 seconds
/// once every 3.5 to 5 seconds (seeded per face). Both loop only while the face shows
/// (`ShownMotionView`), at most 30 frames a second.
final class MovingFaceView: ShownMotionView {
  private let lift = NSView()
  private let outlineHost: NSHostingView<AnyView>
  private let eyesHost: NSHostingView<AnyView>
  private var band: CGRect
  private let blinkPeriod: CFTimeInterval

  init(outline: AnyView, eyes: AnyView, band: CGRect, blinkPeriod: CFTimeInterval) {
    outlineHost = NSHostingView(rootView: outline)
    eyesHost = NSHostingView(rootView: eyes)
    self.band = band
    self.blinkPeriod = blinkPeriod
    super.init(frame: .zero)
    lift.wantsLayer = true
    addSubview(lift)
    for host in [outlineHost, eyesHost] {
      // As large as the frame given, whatever size the content would take.
      host.sizingOptions = []
      host.wantsLayer = true
      lift.addSubview(host)
    }
  }
  required init?(coder: NSCoder) { nil }

  func update(outline: AnyView, eyes: AnyView, band: CGRect) {
    outlineHost.rootView = outline
    eyesHost.rootView = eyes
    if band != self.band {
      self.band = band
      needsLayout = true
    }
  }
  override func layOut() {
    instantly {
      lift.layer?.removeAllAnimations()
      eyesHost.layer?.removeAllAnimations()
      lift.frame = bounds
      outlineHost.frame = lift.bounds
      // AppKit's own coordinates in the lift view put y up; the band is measured from the top.
      let top: CGFloat = lift.isFlipped ? band.minY : lift.bounds.height - band.maxY
      eyesHost.frame = CGRect(x: band.minX, y: top, width: band.width, height: band.height)
    }
  }
  override func loop() {
    guard let whole = lift.layer, let eyes = eyesHost.layer else { return }
    // Up on the screen: toward y 0 where the coordinates are flipped, else toward larger y.
    let flipped: Bool = whole.superlayer?.contentsAreFlipped() ?? true
    let up: CGFloat = flipped ? -1 : 1
    let rise = CABasicAnimation(keyPath: "transform.translation.y")
    rise.fromValue = 0
    rise.toValue = up
    rise.autoreverses = true
    rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    whole.loopInStep(rise, period: 1.2, forKey: "lift")

    // A squash about the band's middle: AppKit anchors a view's layer at a corner.
    let middle: CGFloat = eyes.bounds.height * (0.5 - eyes.anchorPoint.y)
    func squash(_ amount: CGFloat) -> NSValue {
      let moved = CATransform3DMakeTranslation(0, middle, 0)
      let squashed = CATransform3DScale(moved, 1, amount, 1)
      return NSValue(caTransform3D: CATransform3DTranslate(squashed, 0, -middle, 0))
    }
    // Closed for 0.12 seconds of each period: down in 0.06, up in 0.06.
    let period: Double = blinkPeriod
    let half: Double = 0.06 / period
    let blink = CAKeyframeAnimation(keyPath: "transform")
    blink.values = [squash(1), squash(1), squash(0.1), squash(1)]
    let times: [Double] = [0, 1 - 2 * half, 1 - half, 1]
    blink.keyTimes = times.map { NSNumber(value: $0) }
    eyes.loopInStep(blink, period: period, forKey: "blink")
  }
}

extension CALayer {
  /// Repeats `animation` every `period` seconds, forever, on Core Animation's clock, at 30 frames
  /// a second, as `LayerMotion`'s loops do: copies on screen together move in step. One that
  /// autoreverses goes there and back within the period. `ahead` runs this copy that many seconds
  /// ahead (the typing dots, one after another).
  func loopInStep(_ animation: CAPropertyAnimation, period: CFTimeInterval, ahead: CFTimeInterval = 0, forKey key: String) {
    let now: CFTimeInterval = CACurrentMediaTime()
    animation.duration = animation.autoreverses ? period / 2 : period
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    animation.beginTime = convertTime(now, from: nil) - now.truncatingRemainder(dividingBy: period) - ahead
    add(animation, forKey: key)
  }
}

/// Serein's app icon (Icons/serein-app-icon.svg and its light variant), cut to a circle as the
/// boards show it: the main assistant's face. The petal stands in when the file is missing.
struct SereinAppIconImage: View {
  var size: CGFloat
  @Environment(\.palette) private var p
  private static func load(_ name: String) -> NSImage? {
    guard let url = Bundle.assets.url(forResource: name, withExtension: "svg", subdirectory: "Icons") else { return nil }
    return NSImage(contentsOf: url)
  }
  private static let dark = load("serein-app-icon")
  private static let light = load("serein-app-icon-light")
  var body: some View {
    let image: NSImage? = p.isDark ? Self.dark : (Self.light ?? Self.dark)
    Group {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
          .frame(width: size, height: size).clipShape(Circle())
      } else {
        SereinMark(size: size)
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}
