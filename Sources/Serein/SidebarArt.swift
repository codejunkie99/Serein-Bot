import SereinCore
import SwiftUI

/// The sidebar header's picture: today's figure (the start page's petals, from the same date
/// seed) scaled to cover the whole card like a painting, on a graphite-to-indigo ground.
/// It is always still and fully opaque, so it needs no Reduce Motion or Transparency variant.
struct SidebarHeaderArt: View {
  var date = Date()
  @Environment(\.palette) var p
  var body: some View {
    Canvas { g, size in draw(&g, size: size, seed: DailySeed(date: date)) }
      .accessibilityHidden(true)
  }
  func draw(_ g: inout GraphicsContext, size: CGSize, seed: DailySeed) {
    let rect = CGRect(origin: .zero, size: size)
    let ice = p.artIce
    let boost = p.artLineBoost
    let ground = p.artGround
    // Ground: graphite (dark) or pale paper (light) at the top left, under the traffic lights,
    // shading to indigo toward the right.
    g.fill(Path(rect), with: .linearGradient(
      Gradient(stops: [
        .init(color: ground[0], location: 0),
        .init(color: ground[1], location: 0.55),
        .init(color: ground[2], location: 1),
      ]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
    // The figure covers the card: centred a little right of middle, cropped top and bottom.
    let center = CGPoint(x: size.width * (0.50 + (seed.x - 0.74) * 0.6), y: size.height * (0.40 + seed.y * 0.3))
    let radius = size.width * 0.40
    g.fill(Path(ellipseIn: CGRect(x: center.x - radius * 1.5, y: center.y - radius * 1.2,
      width: radius * 3, height: radius * 2.4)),
      with: .radialGradient(Gradient(colors: [p.accentStrong.opacity(p.isDark ? 0.42 : 0.22), p.accent.opacity(0.10), .clear]),
        center: center, startRadius: 0, endRadius: radius * 1.4))
    var orbit = g
    orbit.translateBy(x: center.x, y: center.y)
    for (index, scale) in [0.42, 0.86, 1.3].enumerated() {
      let r = radius * scale
      orbit.stroke(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
        with: .color(ice.opacity((0.10 + Double(index) * 0.03) * boost)),
        style: StrokeStyle(lineWidth: 0.7, dash: index == 1 ? [2, 4] : []))
    }
    for i in 0..<seed.petals {
      var petal = g
      petal.translateBy(x: center.x, y: center.y)
      petal.rotate(by: .degrees(seed.angle + Double(i) * 180 / Double(seed.petals)))
      let h = radius * 1.72
      let w = h * seed.aspect
      let mix = Double(i) / Double(max(1, seed.petals - 1))
      let tint = (mix < seed.split ? p.accent : ice).opacity(min(1, (0.34 + 0.22 * (1 - mix)) * (p.isDark ? 1 : 1.5)))
      petal.stroke(Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)),
        with: .color(tint), lineWidth: 1)
    }
    g.fill(Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)),
      with: .color(p.accent))
    // Keeps the window buttons and the hide button legible over the drawing.
    g.fill(Path(rect), with: .linearGradient(
      Gradient(colors: [p.artTopWash, .clear]),
      startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.45)))
  }
}

/// The status bubble's outline: a rounded rectangle with a small arrow on its leading edge.
struct BubbleShape: Shape {
  var radius: CGFloat = 14
  var arrowY: CGFloat = 26
  var arrowWidth: CGFloat = 8
  var arrowHeight: CGFloat = 16
  func path(in rect: CGRect) -> Path {
    let body = CGRect(x: rect.minX + arrowWidth, y: rect.minY, width: rect.width - arrowWidth, height: rect.height)
    var path = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
    var arrow = Path()
    arrow.move(to: CGPoint(x: body.minX + 1, y: rect.minY + arrowY - arrowHeight / 2))
    arrow.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + arrowY),
      control: CGPoint(x: rect.minX + arrowWidth * 0.35, y: rect.minY + arrowY - 2))
    arrow.addQuadCurve(to: CGPoint(x: body.minX + 1, y: rect.minY + arrowY + arrowHeight / 2),
      control: CGPoint(x: rect.minX + arrowWidth * 0.35, y: rect.minY + arrowY + 2))
    arrow.closeSubpath()
    path.addPath(arrow)
    return path
  }
}

/// The open status bubble, drawn over the whole shell next to its tab row. A click anywhere
/// else or Escape closes it.
struct AgentBubbleLayer: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject private var dock = TaskDock.shared
  @Environment(\.palette) var p
  static let space = "serein-shell"
  var body: some View {
    GeometryReader { geometry in
      if let id = dock.bubbleTabID, let row = dock.rowFrames[id],
        let tab = browser.tabs.first(where: { $0.id == id }) ?? browser.agentTabs.entry(id)?.tab,
        let state = browser.agentState(for: tab)
      {
        let top = min(max(8, row.midY - 26), geometry.size.height - 220)
        ZStack(alignment: .topLeading) {
          AgentStatusBubble(
            state: state, host: URL(string: tab.address)?.host ?? "this tab",
            openTask: { dock.show(state, browser: browser, agent: agent) },
            takeOver: {
              dock.bubbleTabID = nil
              browser.takeOver(tab)
            },
            close: { dock.bubbleTabID = nil }, arrowY: row.midY - top, browser: browser, tab: tab
          )
          .onHover { BubbleHover.inside = $0 }
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
            dock.bubbleFrame = $0
          }
          .offset(x: row.maxX + 4, y: top)
          .transition(.opacity)
        }
      }
    }
  }
}
