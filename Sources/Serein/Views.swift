import SereinCore
import SwiftUI
import WebKit

final class WebHostContainer: NSView {
  private var web: WKWebView?

  init(web: WKWebView) {
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    wantsLayer = true
    clipsToBounds = true
    layer?.masksToBounds = true
    attach(web)
  }

  required init?(coder: NSCoder) { return nil }

  func attach(_ web: WKWebView) {
    // WebKit temporarily reparents the view for element/video fullscreen. A SwiftUI update
    // must leave it there until WebKit restores its placeholder and original parent.
    if self.web === web, web.fullscreenState != .notInFullscreen { return }
    guard self.web !== web || web.superview !== self else { return }
    detach()
    self.web = web
    web.removeFromSuperview()
    web.translatesAutoresizingMaskIntoConstraints = true
    web.autoresizingMask = [.width, .height]
    web.frame = bounds
    addSubview(web)
    setAccessibilityChildren([web])
  }

  override func layout() {
    super.layout()
    if let web, web.superview === self, web.frame != bounds { web.frame = bounds }
  }

  func detach() {
    if let web, web.superview === self { web.removeFromSuperview() }
    setAccessibilityChildren([])
    web = nil
  }
}
struct WebHost: NSViewRepresentable {
  let web: WKWebView
  func makeNSView(context: Context) -> WebHostContainer { WebHostContainer(web: web) }
  func updateNSView(_ nsView: WebHostContainer, context: Context) { nsView.attach(web) }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: WebHostContainer, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width, let height = proposal.height,
      width.isFinite, height.isFinite
    else { return nil }
    return CGSize(width: width.rounded(.down), height: height.rounded(.down))
  }
  static func dismantleNSView(_ nsView: WebHostContainer, coordinator: ()) { nsView.detach() }
}
/// The header over a page a task handed you: its title, then your browser or close. There is no
/// address field: Serein does not browse.
struct HandedPageHeader: View {
  @ObservedObject var browser: BrowserModel
  @Environment(\.palette) var p
  var body: some View {
    HStack(spacing: 8) {
      Button { browser.section = ShellSection.serein } label: {
        Label("Serein", systemImage: "chevron.left").font(UIStyle.meta)
      }.buttonStyle(QuietButton()).foregroundStyle(p.secondary).fixedSize()
      if let tab = browser.active {
        Text(tab.title.isEmpty ? tab.address : tab.title)
          .font(UIStyle.bodyStrong).lineLimit(1).truncationMode(.tail)
        Spacer()
        Button { browser.openInDefaultBrowser(tab.address) } label: {
          InterfaceIcon(systemName: "safari")
        }.buttonStyle(QuietButton()).help("Open in your browser").accessibilityLabel("Open in your browser")
          .disabled(tab.address.isEmpty)
        Button { browser.close(tab, remember: false) } label: {
          InterfaceIcon(systemName: "xmark")
        }.buttonStyle(QuietButton()).help("Close this page").accessibilityLabel("Close this page")
      } else {
        Spacer()
      }
    }
  }
}

struct BrowserPane: View {
  @ObservedObject var tab: BrowserTab
  @Environment(\.palette) var p
  var body: some View {
    ZStack(alignment: .top) {
      WebHost(web: tab.web).id(ObjectIdentifier(tab.web))
      if tab.loading { ProgressView().progressViewStyle(.linear).tint(p.accent).frame(height: 2) }
      PageOverlays(tab: tab, ext: tab.ext)
      AgentPointer(tab: tab)
    }
  }
}

/// Serein's own pointer over an agent's page: an arrow that glides to where the agent is about
/// to act and rings when it gets there. Drawn here, not in the page, so no site can hide it.
struct AgentPointer: View {
  @ObservedObject var tab: BrowserTab
  @State private var ring = false
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) var systemReduceMotion
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  var body: some View {
    GeometryReader { _ in
      if let point = tab.agentPointer {
        ZStack {
          if !reduceMotion {
            Circle().stroke(p.accent, lineWidth: 3).frame(width: 40, height: 40)
              .scaleEffect(ring ? 1.4 : 0.3).opacity(ring ? 0 : 0.95)
          }
          Image(systemName: "cursorarrow").font(.system(size: 30))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 1)
            .shadow(color: .black.opacity(0.7), radius: 4)
            .offset(x: 11, y: 14)
        }
        .position(point)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6), value: tab.agentPointer)
        .transition(.opacity)
        .onChange(of: tab.agentPointerPulse) { _, _ in
          ring = false
          DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.35)) { ring = true } }
        }
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: tab.agentPointer == nil)
    .allowsHitTesting(false).accessibilityHidden(true)
  }
}

extension View {
  /// Opaque card surface, at the panel radius.
  func card(_ p: Palette) -> some View {
    background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
  }
}

/// The primary action: the app's own primary shape.
struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.palette) var p
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(UIStyle.font(14, weight: .semibold))
      .foregroundStyle(p.isDark ? .black : .white)
      .background(
        RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? AnyShapeStyle(p.accent) : AnyShapeStyle(p.ink)))
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}
