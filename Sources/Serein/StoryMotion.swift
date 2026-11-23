import CoreGraphics
import CoreText
import Foundation
import SereinCore

/// A deterministic motion-graphics stage. The visual plan is bounded data; every prop,
/// transition and frame is drawn locally. Paragraphs belong in narration and Read steps.
struct StoryMotion {
  let story: ReplyStory
  var sourceLine: String?
  private let ink = color(0x20332D)
  private let quiet = color(0x62726B)
  private let paper = color(0xFFFEFA)
  private let blue = color(0x6074DA)
  private let mint = color(0x93C7B4)
  private let amber = color(0xEABB62)
  private let coral = color(0xE5A08A)

  func image(scene: Int, progress: Double = 0.64) throws -> CGImage {
    guard let c = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw SereinError.invalid("The illustrated scene could not be created.")
    }
    draw(in: c, scene: scene, progress: progress)
    guard let image = c.makeImage() else { throw SereinError.invalid("The illustrated scene could not be created.") }
    return image
  }

  func draw(in c: CGContext, scene: Int, progress: Double) {
    c.saveGState(); defer { c.restoreGState() }
    c.translateBy(x: 0, y: 720); c.scaleBy(x: 1, y: -1)
    let v = story.visual(scene)
    let t = max(0, min(1, progress))
    rect(c, CGRect(x: 0, y: 0, width: 1280, height: 720), color(0xF5F2E9))
    // A softly lit studio floor, with ample space around the explanatory objects.
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [color(0xE1EADB, alpha: 0.85), color(0xF5F2E9, alpha: 0)] as CFArray, locations: [0, 1]) {
      c.drawRadialGradient(gradient, startCenter: CGPoint(x: 800, y: 380), startRadius: 0,
        endCenter: CGPoint(x: 800, y: 380), endRadius: 540, options: [])
    }
    text(c, story.title, x: 64, y: 32, width: 1136, height: 45, size: 17, fill: quiet)
    c.saveGState()
    text(c, v.headline ?? story.scenes[scene].title, x: 64, y: 91, width: 1152, height: 130,
      size: 53, fill: ink, bold: true)
    c.restoreGState()
    c.saveGState()
    switch v.kind {
    case .gather: gather(c, visual: v, t: t)
    case .compare: compare(c, t: t)
    case .search: search(c, t: t)
    case .result: result(c, visual: v, scene: scene, t: t)
    case .transfer, .hold, .release: transfer(c, visual: v, t: t)
    case .erase: erase(c, scene: scene, t: t)
    case .focus: focus(c, scene: scene, t: t)
    }
    c.restoreGState()
    line(c, CGPoint(x: 64, y: 615), CGPoint(x: 1216, y: 615), fill: color(0xCFD6CC), width: 1)
    text(c, story.caveat, x: 64, y: 631, width: 1152, height: 52, size: 16, fill: quiet)
    if let sourceLine { text(c, sourceLine, x: 64, y: 687, width: 1152, height: 15, size: 10, fill: quiet) }
    let gap = 8.0, width = (1152 - Double(story.scenes.count - 1) * gap) / Double(story.scenes.count)
    for index in story.scenes.indices {
      let x = 64 + Double(index) * (width + gap)
      rounded(c, x: x, y: 709, w: width, h: 3, r: 1.5, fill: color(0xDDE2D7))
      let fill = index < scene ? 1 : index == scene ? t : 0
      if fill > 0 { rounded(c, x: x, y: 709, w: width * fill, h: 3, r: 1.5, fill: ink) }
    }
  }

  private func gather(_ c: CGContext, visual: ReplyStory.Visual, t: Double) {
    let actual = visual.figures?.first
    let count = min(5, max(0, actual?.value ?? 3))
    ellipse(c, CGRect(x: 390, y: 502, width: 500, height: 30), color(0x24382B, alpha: 0.07))
    for i in 0..<count {
      let f = Double(i) - Double(count - 1) / 2
      let arrived = ease((t - Double(i) * 0.065) * 3)
      let x = 640 + f * (62 + (1 - arrived) * 150)
      let y = 391 + abs(f) * 12 + (1 - arrived) * 30
      prop(c, .page, at: CGPoint(x: x, y: y), scale: 1.05,
        accent: i % 2 == 0 ? blue : mint, rotation: f * 0.1 * (1 - arrived * 0.5))
    }
    if count == 0 {
      rounded(c, x: 550, y: 300, w: 180, h: 200, r: 20, fill: color(0xE4E8DE))
      text(c, "0", x: 550, y: 339, width: 180, height: 100, size: 80, fill: quiet, bold: true, center: true)
    }
    if let actual {
      text(c, "\(actual.value)  \(actual.label.lowercased())", x: 340, y: 548, width: 600, height: 40, size: 25, fill: ink, center: true)
    }
  }

  private func compare(_ c: CGContext, t: Double) {
    prop(c, .page, at: CGPoint(x: 352, y: 399), scale: 1.1, accent: blue, rotation: -0.06)
    prop(c, .page, at: CGPoint(x: 928, y: 399), scale: 1.1, accent: coral, rotation: 0.06)
    let match = ease((t - 0.13) * 2)
    for i in 0..<2 {
      let start = i == 0 ? 352.0 : 928.0
      let end = i == 0 ? 584.0 : 696.0
      let x = start + (end - start) * match
      let y = 374 + Double(i) * 46
      rounded(c, x: x - 75, y: y, w: 150, h: 26, r: 7, fill: i == 0 ? blue : coral)
      for j in 0..<3 { rounded(c, x: x - 56 + Double(j) * 35, y: y + 10, w: 25, h: 5, r: 2, fill: paper.copy(alpha: 0.75)!) }
    }
    lens(c, at: CGPoint(x: 640 + sin(t * .pi * 2) * 28, y: 396), size: 87, accent: mint)
    text(c, "Source", x: 242, y: 548, width: 220, height: 38, size: 23, fill: ink, center: true)
    text(c, "Comparison", x: 818, y: 548, width: 220, height: 38, size: 23, fill: ink, center: true)
  }

  private func search(_ c: CGContext, t: Double) {
    let locations = [CGPoint(x: 330, y: 335), CGPoint(x: 855, y: 320), CGPoint(x: 1030, y: 450), CGPoint(x: 520, y: 467)]
    for (i, point) in locations.enumerated() {
      let show = ease((t - Double(i) * 0.045) * 4)
      c.saveGState(); c.setAlpha(0.3 + show * 0.7)
      prop(c, .page, at: CGPoint(x: point.x, y: point.y + (1 - show) * 30), scale: 0.64,
        accent: i % 2 == 0 ? blue : mint, rotation: i % 2 == 0 ? -0.09 : 0.09)
      c.restoreGState()
    }
    let x = 640 + sin((t * 1.1 - 0.2) * .pi * 2) * 180
    let y = 360 + cos(t * .pi * 2) * 25
    lens(c, at: CGPoint(x: x, y: y), size: 104, accent: amber)
    text(c, "Find → read → check", x: 340, y: 554, width: 600, height: 38, size: 23, fill: ink, center: true)
  }

  private func result(_ c: CGContext, visual: ReplyStory.Visual, scene: Int, t: Double) {
    guard let figures = visual.figures, !figures.isEmpty else { focus(c, scene: scene, t: t); return }
    let colors = [mint, coral, amber]
    let span = 920.0 / Double(figures.count)
    for (i, figure) in figures.enumerated() {
      let x = 180 + span * (Double(i) + 0.5)
      let appear = ease((t - Double(i) * 0.08) * 4)
      let radius = 80 + appear * 15
      ellipse(c, CGRect(x: x - radius, y: 387 - radius, width: radius * 2, height: radius * 2),
        figure.value == 0 ? color(0xE3E8DE) : colors[i])
      if figure.value > 0 {
        for j in 0..<min(figure.value, 7) {
          let angle = Double(j) * .pi * 2 / Double(min(figure.value, 7)) - .pi / 2
          let r = 114 + sin(t * .pi * 2 + Double(j)) * 5
          token(c, at: CGPoint(x: x + cos(angle) * r, y: 387 + sin(angle) * r), size: 13, fill: colors[i], rotation: t * 0.5)
        }
      }
      text(c, String(figure.value), x: x - 100, y: 327, width: 200, height: 112, size: figure.value < 1000 ? 91 : figure.value < 100000 ? 64 : 44, fill: ink, bold: true, center: true)
      text(c, figure.label, x: x - span / 2 + 8, y: 529, width: span - 16, height: 60, size: 25, fill: ink, center: true)
    }
  }

  private func transfer(_ c: CGContext, visual: ReplyStory.Visual, t: Double) {
    guard let from = visual.from, let to = visual.to, story.nodes.indices.contains(from), story.nodes.indices.contains(to) else { return }
    let left = CGPoint(x: 300, y: 396), right = CGPoint(x: 980, y: 396)
    line(c, CGPoint(x: 420, y: 400), CGPoint(x: 860, y: 400), fill: color(0xD8DFD3), width: 3)
    prop(c, story.icons?[from] ?? .page, at: left, scale: 1.05, accent: blue)
    c.saveGState(); c.setAlpha(visual.kind == .hold ? 0.38 : 1)
    prop(c, story.icons?[to] ?? .page, at: right, scale: 1.05, accent: mint)
    c.restoreGState()
    if visual.kind == .hold || visual.kind == .release {
      let opening = visual.kind == .release ? ease((t - 0.16) * 4) : 0
      c.saveGState(); c.setAlpha(1 - opening)
      rounded(c, x: 628, y: 300 - opening * 110, w: 24, h: 184 * (1 - opening) + 14, r: 12, fill: amber)
      c.restoreGState()
      if opening < 0.5 { line(c, CGPoint(x: 627, y: 324), CGPoint(x: 652, y: 345), fill: paper, width: 4) }
    }
    for i in 0..<5 {
      let shift = Double(i) * 0.075
      let p = visual.kind == .hold ? min(0.34, ease((t - shift) * 2) * 0.34) : ease((t - shift - (visual.kind == .release ? 0.18 : 0.05)) * 1.8)
      let x = 400 + p * 480 - (visual.kind == .hold ? Double(i) * 21 : 0)
      let y = 400 - sin(p * .pi) * 90 + (visual.kind == .hold ? sin(t * .pi * 3 + Double(i)) * 4 : 0)
      token(c, at: CGPoint(x: x, y: y), size: 21, fill: i % 2 == 0 ? blue : mint, rotation: p * .pi / 2)
    }
    text(c, story.nodes[from], x: 165, y: 546, width: 270, height: 54, size: 24, fill: ink, center: true)
    text(c, story.nodes[to], x: 845, y: 546, width: 270, height: 54, size: 24, fill: ink, center: true)
  }

  private func erase(_ c: CGContext, scene: Int, t: Double) {
    let index = story.scenes[scene].focus
    prop(c, story.icons?[index] ?? .memory, at: CGPoint(x: 640, y: 394), scale: 1.2, accent: mint)
    let gone = ease((t - 0.25) * 2)
    for i in 0..<6 {
      let a = Double(i) * .pi / 3
      c.saveGState(); c.setAlpha(1 - gone)
      token(c, at: CGPoint(x: 640 + cos(a) * (90 + gone * 150), y: 390 + sin(a) * (70 + gone * 130)),
        size: 24 * (1 - gone * 0.8), fill: coral, rotation: a + gone * 2)
      c.restoreGState()
    }
    text(c, story.nodes[index], x: 380, y: 550, width: 520, height: 42, size: 25, fill: ink, center: true)
  }

  private func focus(_ c: CGContext, scene: Int, t: Double) {
    let focus = story.scenes[scene].focus
    let others = story.nodes.indices.filter { $0 != focus }
    for (slot, index) in others.enumerated() {
      let x = slot % 2 == 0 ? 250.0 : 1030.0
      c.saveGState(); c.setAlpha(0.3)
      prop(c, story.icons?[index] ?? .page, at: CGPoint(x: x, y: 348 + Double(slot / 2) * 130), scale: 0.55, accent: mint,
        rotation: index < focus ? -0.12 : 0.12)
      c.restoreGState()
    }
    prop(c, story.icons?[focus] ?? .page, at: CGPoint(x: 640, y: 390 + sin(t * .pi * 2) * 6), scale: 1.3, accent: blue)
    text(c, story.nodes[focus], x: 370, y: 552, width: 540, height: 40, size: 26, fill: ink, center: true)
  }

  private func prop(_ c: CGContext, _ icon: ReplyStory.Icon, at point: CGPoint, scale: Double, accent: CGColor, rotation: Double = 0) {
    c.saveGState(); defer { c.restoreGState() }
    c.translateBy(x: point.x, y: point.y); c.rotate(by: rotation); c.scaleBy(x: scale, y: scale)
    c.setShadow(offset: CGSize(width: 0, height: -13), blur: 20, color: color(0x263E2E, alpha: 0.12))
    switch icon {
    case .page, .compare, .result:
      rounded(c, x: -84, y: -105, w: 168, h: 210, r: 17, fill: paper)
      c.setShadow(offset: .zero, blur: 0)
      rounded(c, x: -61, y: -77, w: 67, h: 12, r: 5, fill: accent)
      for i in 0..<5 { rounded(c, x: -61, y: -40 + Double(i) * 26, w: i == 4 ? 73 : 122, h: 7, r: 3.5, fill: color(0xC5D0C8)) }
      rounded(c, x: -65, y: 2, w: 130, h: 22, r: 5, fill: accent.copy(alpha: 0.38)!)
    case .app:
      rounded(c, x: -119, y: -82, w: 238, h: 155, r: 17, fill: ink)
      c.setShadow(offset: .zero, blur: 0)
      rounded(c, x: -108, y: -70, w: 216, h: 131, r: 8, fill: paper)
      rounded(c, x: -108, y: -70, w: 216, h: 24, r: 6, fill: accent)
      for i in 0..<3 { ellipse(c, CGRect(x: -96 + Double(i) * 13, y: -62, width: 5, height: 5), paper) }
      rounded(c, x: -78, y: -25, w: 66, h: 60, r: 8, fill: mint)
      for i in 0..<3 { rounded(c, x: 4, y: -20 + Double(i) * 19, w: 70 - Double(i) * 8, h: 7, r: 3, fill: color(0xC6D2CA)) }
      polygon(c, [CGPoint(x: -135, y: 77), CGPoint(x: 135, y: 77), CGPoint(x: 111, y: 96), CGPoint(x: -111, y: 96)], fill: color(0xACBCB2))
    case .memory:
      rounded(c, x: -104, y: -64, w: 208, h: 128, r: 16, fill: color(0x5F9881))
      c.setShadow(offset: .zero, blur: 0)
      for i in 0..<8 {
        rounded(c, x: -88 + Double(i) * 24, y: -78, w: 12, h: 20, r: 3, fill: amber)
        rounded(c, x: -88 + Double(i) * 24, y: 57, w: 12, h: 20, r: 3, fill: amber)
      }
      for i in 0..<3 { rounded(c, x: -82 + Double(i) * 58, y: -34, w: 48, h: 68, r: 7, fill: ink) }
      for i in 0..<3 { line(c, CGPoint(x: -74 + Double(i) * 58, y: 24), CGPoint(x: -48 + Double(i) * 58, y: 24), fill: mint, width: 3) }
    case .disk:
      rounded(c, x: -91, y: -106, w: 182, h: 210, r: 28, fill: color(0xB6C4B9))
      c.setShadow(offset: .zero, blur: 0)
      rounded(c, x: -80, y: -98, w: 160, h: 184, r: 23, fill: paper)
      ellipse(c, CGRect(x: -53, y: -67, width: 106, height: 106), accent.copy(alpha: 0.4)!)
      ellipse(c, CGRect(x: -19, y: -33, width: 38, height: 38), paper)
      ellipse(c, CGRect(x: -7, y: -21, width: 14, height: 14), ink)
      line(c, CGPoint(x: 52, y: 41), CGPoint(x: 5, y: -10), fill: ink, width: 9)
      rounded(c, x: -62, y: 61, w: 75, h: 7, r: 3, fill: color(0xC5D0C8))
      ellipse(c, CGRect(x: 52, y: 61, width: 8, height: 8), color(0x507C69))
    case .parcel:
      rounded(c, x: -93, y: -80, w: 186, h: 164, r: 12, fill: amber)
      c.setShadow(offset: .zero, blur: 0)
      rect(c, CGRect(x: -15, y: -80, width: 30, height: 164), color(0xF3D8A4))
      rounded(c, x: -68, y: 9, w: 64, h: 42, r: 4, fill: paper)
      for i in 0..<7 { rect(c, CGRect(x: -60 + Double(i) * 7, y: 18, width: i % 2 == 0 ? 2 : 4, height: 19), ink) }
    case .truck:
      rounded(c, x: -123, y: -65, w: 163, h: 116, r: 12, fill: accent)
      c.setShadow(offset: .zero, blur: 0)
      rounded(c, x: 40, y: -30, w: 82, h: 81, r: 12, fill: amber)
      rounded(c, x: 53, y: -17, w: 52, h: 33, r: 5, fill: paper)
      for x in [-74.0, 79.0] { ellipse(c, CGRect(x: x - 25, y: 30, width: 50, height: 50), ink); ellipse(c, CGRect(x: x - 10, y: 45, width: 20, height: 20), paper) }
    case .search:
      c.setShadow(offset: .zero, blur: 0); lens(c, at: .zero, size: 78, accent: accent)
    case .person:
      ellipse(c, CGRect(x: -48, y: -100, width: 96, height: 96), coral)
      rounded(c, x: -86, y: 12, w: 172, h: 98, r: 45, fill: accent)
      c.setShadow(offset: .zero, blur: 0)
      ellipse(c, CGRect(x: -23, y: -59, width: 7, height: 7), ink); ellipse(c, CGRect(x: 17, y: -59, width: 7, height: 7), ink)
    case .clock:
      ellipse(c, CGRect(x: -92, y: -92, width: 184, height: 184), paper)
      c.setShadow(offset: .zero, blur: 0)
      for i in 0..<12 { let a = Double(i) * .pi / 6; line(c, CGPoint(x: sin(a) * 73, y: cos(a) * 73), CGPoint(x: sin(a) * 79, y: cos(a) * 79), fill: quiet, width: 3) }
      line(c, .zero, CGPoint(x: 0, y: -52), fill: ink, width: 7); line(c, .zero, CGPoint(x: 40, y: 22), fill: accent, width: 7)
    case .cloud:
      for r in [CGRect(x: -95, y: -27, width: 110, height: 110), CGRect(x: -45, y: -77, width: 143, height: 143), CGRect(x: 28, y: -22, width: 91, height: 100)] { ellipse(c, r, paper) }
      rounded(c, x: -45, y: 13, w: 110, h: 68, r: 10, fill: paper)
    case .energy:
      polygon(c, [CGPoint(x: 20, y: -115), CGPoint(x: -64, y: 12), CGPoint(x: -7, y: 12), CGPoint(x: -23, y: 112), CGPoint(x: 72, y: -26), CGPoint(x: 13, y: -26)], fill: amber)
    case .warning:
      polygon(c, [CGPoint(x: 0, y: -102), CGPoint(x: 113, y: 84), CGPoint(x: -113, y: 84)], fill: amber)
      c.setShadow(offset: .zero, blur: 0)
      rounded(c, x: -7, y: -35, w: 14, h: 66, r: 7, fill: ink); ellipse(c, CGRect(x: -7, y: 47, width: 14, height: 14), ink)
    }
  }

  private func lens(_ c: CGContext, at p: CGPoint, size: Double, accent: CGColor) {
    c.saveGState(); defer { c.restoreGState() }
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 16, color: color(0x20332D, alpha: 0.12))
    line(c, CGPoint(x: p.x + size * 0.7, y: p.y + size * 0.7), CGPoint(x: p.x + size * 1.3, y: p.y + size * 1.3), fill: ink, width: 24)
    ellipse(c, CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2), accent.copy(alpha: 0.3)!)
    c.setShadow(offset: .zero, blur: 0); c.setStrokeColor(ink); c.setLineWidth(10)
    c.strokeEllipse(in: CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2))
    c.setStrokeColor(paper.copy(alpha: 0.8)!); c.setLineWidth(5)
    c.addArc(center: p, radius: size - 17, startAngle: .pi * 1.06, endAngle: .pi * 1.47, clockwise: false); c.strokePath()
  }

  private func token(_ c: CGContext, at p: CGPoint, size: Double, fill: CGColor, rotation: Double) {
    c.saveGState(); c.translateBy(x: p.x, y: p.y); c.rotate(by: rotation)
    c.setShadow(offset: CGSize(width: 0, height: -4), blur: 5, color: color(0x20332D, alpha: 0.12))
    rounded(c, x: -size / 2, y: -size / 2, w: size, h: size, r: size * 0.22, fill: fill)
    c.restoreGState()
  }
}

private func color(_ hex: Int, alpha: Double = 1) -> CGColor {
  CGColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: alpha)
}
private func ease(_ value: Double) -> Double { let t = min(1, max(0, value)); return 1 - pow(1 - t, 3) }
private func rect(_ c: CGContext, _ r: CGRect, _ fill: CGColor) { c.setFillColor(fill); c.fill(r) }
private func ellipse(_ c: CGContext, _ r: CGRect, _ fill: CGColor) { c.setFillColor(fill); c.fillEllipse(in: r) }
private func rounded(_ c: CGContext, x: Double, y: Double, w: Double, h: Double, r: Double, fill: CGColor) {
  c.setFillColor(fill); c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)); c.fillPath()
}
private func line(_ c: CGContext, _ a: CGPoint, _ b: CGPoint, fill: CGColor, width: Double) {
  c.setStrokeColor(fill); c.setLineWidth(width); c.setLineCap(.round); c.move(to: a); c.addLine(to: b); c.strokePath()
}
private func polygon(_ c: CGContext, _ points: [CGPoint], fill: CGColor) {
  guard let first = points.first else { return }; c.setFillColor(fill); c.move(to: first)
  for point in points.dropFirst() { c.addLine(to: point) }; c.closePath(); c.fillPath()
}
private func text(_ c: CGContext, _ words: String, x: Double, y: Double, width: Double, height: Double, size: Double, fill: CGColor, bold: Bool = false, center: Bool = false) {
  var fontSize = size
  var framesetter: CTFramesetter!
  repeat {
    let font = CTFontCreateWithName((bold ? "Geist-SemiBold" : "Geist-Regular") as CFString, fontSize, nil)
    var alignment: CTTextAlignment = center ? .center : .left
    let paragraph = withUnsafePointer(to: &alignment) { pointer in
      var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
      return CTParagraphStyleCreate(&setting, 1)
    }
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
      NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph]
    framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: words, attributes: attributes))
    let fits = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: width, height: 1000), nil).height <= height
    if fits || fontSize <= size * 0.68 { break }; fontSize -= 1
  } while true
  c.saveGState(); c.translateBy(x: x, y: y + height); c.scaleBy(x: 1, y: -1); c.textMatrix = .identity
  CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil), c)
  c.restoreGState()
}
