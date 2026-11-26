import SereinCore
import SwiftUI
import AppKit

enum Palette: String, CaseIterable, Identifiable {
  /// Grok's flat dark set.
  case dusk = "Graphite"
  /// Grok's light set (#1C1C1C washes, near-black primary plate).
  case light = "Paper"
  var id: String { rawValue }
  init(_ scheme: AppearanceScheme) { self = scheme == .dark ? .dusk : .light }
  var scheme: AppearanceScheme { self == .dusk ? .dark : .light }
  var isDark: Bool { self == .dusk }
  /// The sRGB values live in SereinCore (`ThemeTokens`) so the contrast checks test them.
  var tokens: ThemeTokens { ThemeTokens.tokens(scheme) }
  var colorScheme: ColorScheme { isDark ? .dark : .light }
  var background: Color { Color(hex: tokens.background) }
  var sidebar: Color { Color(hex: tokens.sidebar) }
  var panel: Color { Color(hex: tokens.panel) }
  var card: Color { Color(hex: tokens.card) }
  var overlay: Color { Color(hex: tokens.overlay) }
  /// Pills and the message bar, with no outline: `overlay` is white in light, so they use `track` there.
  var pill: Color { isDark ? overlay : track }
  var raised: Color { Color(hex: tokens.raised) }
  var ink: Color { Color(hex: tokens.ink) }
  var secondary: Color { Color(hex: tokens.secondary) }
  /// Dark: lifted from the source #737373 (4.27:1) so small faint text clears 4.5:1 on every
  /// opaque plane below `raised`.
  var faint: Color { Color(hex: tokens.faint) }
  var accent: Color { Color(hex: tokens.accent) }
  var accentStrong: Color { Color(hex: tokens.accentStrong) }
  var line: Color { Color(wash: tokens.line) }
  var borderStrong: Color { Color(wash: tokens.borderStrong) }
  var hover: Color { Color(wash: tokens.hover) }
  var selected: Color { Color(wash: tokens.selected) }
  /// The primary action plate: white in dark, near-black in light.
  var solid: Color { Color(hex: tokens.solid) }
  var onSolid: Color { Color(hex: tokens.onSolid) }
  var onAccent: Color { Color(hex: tokens.onAccent) }
  var success: Color { Color(hex: tokens.success) }
  var danger: Color { Color(hex: tokens.danger) }
  /// Certificate problems, key conflicts and other cautions that are not failures.
  var warning: Color { Color(hex: tokens.warning) }
  /// Dims the workspace under a modal card or the composer overlay.
  var scrim: Color { Color(wash: tokens.scrim) }
  /// Soft neutral wash for the user's own messages (thread and Ask panel).
  var bubble: Color { Color(wash: tokens.bubble) }
  /// Empty part of meters, progress tracks and quiet tag pills.
  var track: Color { Color(wash: tokens.track) }
  /// Private windows keep a violet tint in both appearances.
  var privateBackground: Color { Color(hex: tokens.privateBackground) }
  var privateAccent: Color { Color(hex: tokens.privateAccent) }
  /// A merged pull request: the same violet, as GitHub marks merges.
  var merged: Color { Color(hex: tokens.privateAccent) }
  /// Edge highlight on plates and glass: white in dark, a soft black hairline in light.
  var edge: Color { isDark ? Color(hex: 0xF5F5F5).opacity(0.10) : Color(hex: 0x1C1C1C).opacity(0.122) }
  /// Soft drop shadow under floating surfaces in light. Dark is flat, as Grok's: `edge` rings it instead.
  func shadow(_ darkOpacity: Double) -> Color {
    Color.black.opacity(isDark ? 0 : darkOpacity * 0.4)
  }
  /// The daily drawing's second line color: pale ice on dark, a deeper blue on light.
  var artIce: Color { isDark ? Color(hex: 0xA8C7FF) : Color(hex: 0x3550B0) }
  /// The sidebar header card's ground, top-left (under the traffic lights) to bottom-right.
  var artGround: [Color] {
    isDark
      ? [Color(hex: 0x111216), Color(hex: 0x181A2C), Color(hex: 0x23264A)]
      : [Color(hex: 0xF7F7FA), Color(hex: 0xECEDF9), Color(hex: 0xDADDF6)]
  }
  /// How strongly the drawing's lines show; light needs more ink to read on a pale ground.
  var artLineBoost: Double { isDark ? 1 : 1.9 }
  /// Code panels in the transcript: the body wash and the slightly stronger header strip.
  var codePanel: Color { isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.03) }
  var codeHeader: Color { isDark ? Color.white.opacity(0.02) : Color.black.opacity(0.02) }
  /// The wash along the top of the header art that keeps the window buttons legible.
  var artTopWash: Color { isDark ? Color.black.opacity(0.35) : Color.white.opacity(0.5) }
  /// The moving highlight on a working agent's status bar (reads on indigo in both themes).
  var shimmer: Color { Color.white.opacity(0.85) }
  /// Grok's `--color-border-tertiary`: the 0.5 hairline on panel cards, round buttons and dividers.
  var hairline: Color { isDark ? Color(hex: 0xF5F5F5).opacity(0.059) : Color(hex: 0x1C1C1C).opacity(0.078) }
  /// Grok's `--color-border-focus`: the keyboard's ring (`keyboardFocusRing`) and the 2-point
  /// frame round a computer screen the person controls.
  var focus: Color { Color(hex: tokens.focus) }
  /// The hairline around raised pills.
  var raisedEdge: Color { isDark ? Color(hex: 0xF5F5F5).opacity(0.10) : Color(hex: 0x1C1C1C).opacity(0.078) }
  /// Serein's hologram mark (`SereinHologramMark`): its orbit lines and its bright core, as
  /// the header film draws them (pale lavender on dark, the accent on light).
  var hologramLine: Color { isDark ? Color(hex: 0xB4B8FF) : accent }
  var hologramCore: Color { isDark ? Color(hex: 0xF2F3FF) : accent }
  /// Your messages in Serein's chat and your initial in the sidebar, with white words: Grok's
  /// user bubble for a black bot (#1C1C1C in light, #F5F5F5 at 18% in dark).
  var userBubble: Color { isDark ? Color(hex: 0xF5F5F5).opacity(0.18) : Color(hex: 0x1C1C1C) }
  /// Serein's messages in its chat: the neutral bubble wash.
  var assistantBubble: Color { bubble }
  /// AppKit colors for window and web view backgrounds; they follow the effective appearance.
  static func dynamic(_ token: @escaping (ThemeTokens) -> UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return NSColor(hex: token(dark ? .dark : .light))
    }
  }
  /// The palette the app currently resolves to, for code outside a view's environment.
  @MainActor static var current: Palette { AppearanceController.shared.palette }
}

/// Source dimensions are shared by every active screen, including native sheets.
enum UIStyle {
  /// One device pixel: 0.5 pt on Retina, 1 pt on a 1x display, where a 0.5 pt line falls on half a
  /// pixel and fades in and out along its edge. The least sharp screen attached decides, so a
  /// window moved to it keeps whole edges.
  static var hairline: CGFloat { 1 / max(NSScreen.screens.map(\.backingScaleFactor).min() ?? 2, 1) }
  /// Grows with the text size so the sidebar's labels keep their room.
  static var sidebarWidth: CGFloat { (256 * textScale).rounded() }
  static let titlebarHeight: CGFloat = 38
  static let headerHeight: CGFloat = 44
  static let panelRadius: CGFloat = 10
  static let controlRadius: CGFloat = 6
  static let rowRadius: CGFloat = 8
  static let composerWidth: CGFloat = 768
  static let composerRadius: CGFloat = 26
  /// One corner for every chat bubble, Serein's chat and task threads alike.
  static let bubbleRadius: CGFloat = AssistantMetrics.bubbleRadius
  /// The keyboard's ring on a control that draws its own chrome: this wide and this far out
  /// (`keyboardFocusRing`).
  static let focusRing: CGFloat = 2
  /// Library pages (History, Projects, Saved, Today, Settings) share one gutter and top inset.
  static let pageGutter: CGFloat = 32
  static let pageTop: CGFloat = 28
  /// Content column caps: lists read at 768, card grids at 960.
  static let listWidth: CGFloat = 768
  static let cardsWidth: CGFloat = 960
  /// SF Pro, as Grok sets it.
  static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size * textScale, weight: weight)
  }
  static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size * textScale, weight: weight == .bold ? .bold : .regular, design: .monospaced)
  }
  /// Settings › General › Text size, applied to every font above (TextSizeController).
  nonisolated(unsafe) static var textScale: CGFloat = 1
  /// A width that holds words (a menu, a popover, a column): it grows with a text size above
  /// 100%, so the words in it are not cut. At 100% and below it is the given width.
  static func wide(_ points: CGFloat) -> CGFloat { (points * max(1, textScale)).rounded() }
}
/// The seven type roles. Every text call picks one of these instead of a literal size.
enum TypeRole {
  /// 30 medium, tracking -0.6: the start greeting and the History headline.
  case display
  /// 20 semibold, tracking -0.3: every page title.
  case title
  /// 15 medium: group headers and card titles.
  case section
  /// 13 regular: interface text.
  case body
  /// 14 with 22-point lines: transcript, Ask panel and journal summaries.
  case reading
  /// 12 regular, secondary: supporting text and help under a control.
  case meta
  /// 11 regular, faint: counts, timestamps and key hints (numbers in mono).
  case micro
  var font: Font {
    switch self {
    case .display: return UIStyle.font(30, weight: .medium)
    case .title: return UIStyle.font(20, weight: .semibold)
    case .section: return UIStyle.font(15, weight: .medium)
    case .body: return UIStyle.font(13)
    case .reading: return UIStyle.font(14)
    case .meta: return UIStyle.font(12)
    case .micro: return UIStyle.font(11)
    }
  }
  var tracking: CGFloat {
    switch self {
    case .display: return -0.6
    case .title: return -0.3
    default: return 0
    }
  }
  var lineSpacing: CGFloat { self == .reading ? 5 : 0 }
}
extension UIStyle {
  // Computed, not stored: a stored font keeps the text size of its first use, so a change of
  // the text size in Settings reached these only after Serein opened again.
  static var display: Font { TypeRole.display.font }
  static var title: Font { TypeRole.title.font }
  static var section: Font { TypeRole.section.font }
  static var body: Font { TypeRole.body.font }
  static var reading: Font { TypeRole.reading.font }
  static var meta: Font { TypeRole.meta.font }
  static var micro: Font { TypeRole.micro.font }
  /// Numbers, times and key glyphs at the micro size.
  static var microMono: Font { UIStyle.mono(11) }
  /// Medium body (13) and meta (12). Weight marks only what the eye looks for: the one name per
  /// row, panel headers, primary buttons and table headers. Group labels, counts, status, chips,
  /// quiet buttons and selected rows stay regular; selection shows in the background, not the weight.
  static var bodyStrong: Font { UIStyle.font(13, weight: .medium) }
  static var metaStrong: Font { UIStyle.font(12, weight: .medium) }
  /// Paths, hosts and code-like values at the meta size.
  static var monoMeta: Font { UIStyle.mono(12) }
}
private struct TypeRoleModifier: ViewModifier {
  var role: TypeRole
  @Environment(\.palette) var p
  func body(content: Content) -> some View {
    let styled = content.font(role.font).tracking(role.tracking).lineSpacing(role.lineSpacing)
    switch role {
    case .meta: styled.foregroundStyle(p.secondary)
    case .micro: styled.foregroundStyle(p.faint)
    default: styled
    }
  }
}
extension View {
  /// Applies a type role: font, tracking, line spacing and, for meta and micro, the role's color.
  func role(_ role: TypeRole) -> some View { modifier(TypeRoleModifier(role: role)) }
}

// MARK: - Personal-assistant screens

/// Motion on the personal-assistant screens (SPEC.md 10.2; DESIGN.md › Personal-assistant
/// screens): the assistant list, chats, cards, welcome and library. Only opacity and transform
/// move; layout size never animates on a list (the dashboard's own height is the one exception).
/// Under Reduce Motion every moment is a 0.10-second fade with no movement, spring, shimmer or
/// loop. The numbers are to move into SereinCore's `MotionTokens` (unit A21) so checks read them.
enum Motion {
  /// A part that comes in: 0.16 seconds on Grok's ease-out (0.2, 0, 0, 1), a fade and a 6-point rise.
  static let enterDuration: Double = 0.16
  /// A part that goes: 0.12 seconds on the same curve, a fade and a 4-point drop.
  static let exitDuration: Double = 0.12
  /// One content changes to another (a switch of assistant, a label): a 0.12-second crossfade.
  static let swapDuration: Double = 0.12
  /// A pressed control shrinks to 0.97 in 0.06 seconds and comes back in 0.12.
  static let pressDuration: Double = 0.06
  static let releaseDuration: Double = 0.12
  static let pressScale: CGFloat = 0.97
  /// The shimmer's linear loop over the words of a wait.
  static let shimmerDuration: Double = 1.6
  /// Reduce Motion: a fade only.
  static let reducedDuration: Double = 0.10
  /// How far a part that comes in rises, and how far one that goes drops.
  static let rise: CGFloat = 6
  static let drop: CGFloat = 4
  static var enter: Animation { .timingCurve(0.2, 0, 0, 1, duration: enterDuration) }
  static var exit: Animation { .timingCurve(0.2, 0, 0, 1, duration: exitDuration) }
  static var swap: Animation { .easeInOut(duration: swapDuration) }
  /// Spring response 0.28 seconds, damping 0.86.
  static var pop: Animation { .spring(response: 0.28, dampingFraction: 0.86) }
  static var press: Animation { .easeOut(duration: pressDuration) }
  static var release: Animation { .easeOut(duration: releaseDuration) }
  static var shimmer: Animation { .linear(duration: shimmerDuration).repeatForever(autoreverses: false) }
  /// A skeleton block's slow pulse while what it stands for loads.
  static var skeleton: Animation { .easeInOut(duration: shimmerDuration / 2).repeatForever(autoreverses: true) }
  static var reduced: Animation { .easeInOut(duration: reducedDuration) }
  /// `enter`, or the 0.10-second fade under Reduce Motion.
  static func entering(_ reduce: Bool) -> Animation { reduce ? reduced : enter }
  static func leaving(_ reduce: Bool) -> Animation { reduce ? reduced : exit }
  static func swapping(_ reduce: Bool) -> Animation { reduce ? reduced : swap }
  static func popping(_ reduce: Bool) -> Animation { reduce ? reduced : pop }
  /// A part that comes in fades and rises 6 points; one that goes fades and drops 4; under
  /// Reduce Motion each only fades.
  static func arrival(_ reduce: Bool) -> AnyTransition {
    if reduce { return AnyTransition.opacity.animation(reduced) }
    let rising: AnyTransition = AnyTransition.opacity.combined(with: .offset(y: rise))
    let dropping: AnyTransition = AnyTransition.opacity.combined(with: .offset(y: drop))
    return AnyTransition.asymmetric(insertion: rising.animation(enter), removal: dropping.animation(exit))
  }
}

/// The type of the personal-assistant screens (SPEC.md 2.0): title 16, body 13, meta 12, medium
/// (500) only for names and titles, regular (400) for everything else, and numbers in Geist Mono
/// 12. The rest of Serein keeps `TypeRole`.
enum AssistantType {
  static var title: Font { UIStyle.font(16, weight: .medium) }
  static var name: Font { UIStyle.font(13, weight: .medium) }
  static var body: Font { UIStyle.font(13) }
  /// The words in a chat's message bubbles: Grok's 15.
  static var bubble: Font { UIStyle.font(15) }
  static var meta: Font { UIStyle.font(12) }
  /// Elapsed time, counts, sizes and codes.
  static var figures: Font { UIStyle.mono(12) }
}

/// The measures of the personal-assistant screens (SPEC.md 2.0; the Nb boards scaled by 232/320
/// to the sidebar).
enum AssistantMetrics {
  /// Plan, dashboard, details and routine cards.
  static let cardRadius: CGFloat = 20
  /// Approval sheets.
  static let sheetRadius: CGFloat = 18
  /// Sign-in frames (the key field).
  static let signInRadius: CGFloat = 22
  static let bubbleRadius: CGFloat = 18
  static let bannerRadius: CGFloat = 14
  /// The message bar, and the height every one-line field and its placeholder centre in.
  static let barHeight: CGFloat = 44
  static let bubbleMax: CGFloat = 560
  static let replyMax: CGFloat = 560
  /// Between the bubbles of one reply.
  static let bubbleGap: CGFloat = 4
  /// The chat column: at most 640 wide, centred.
  static let column: CGFloat = 640
  /// A reply's face, and the gap to its words; cards under a reply start after both (38).
  /// Between the welcome's parts and between chips. The chat itself is spaced by turn (below).
  static let chatGap: CGFloat = 12
  /// Within one turn: the person's message and everything Serein shows for it (trail, tool rows,
  /// cards, receipts, reply, its actions and sources) sit this close, so they read as one block.
  static let turnInnerGap: CGFloat = 6
  /// Between one turn and the next: the room in a chat goes here (`ChatTurns`).
  static let turnGap: CGFloat = 24
  static let cardGap: CGFloat = 12
  static let chipGap: CGFloat = 8
  static let cardWide: CGFloat = 414
  static let cardNarrow: CGFloat = 340
  /// Compact sidebar rows keep their density when widened; text-size accessibility still scales them.
  static let listFace: CGFloat = 18
  static let listRowHeight: CGFloat = 30
  static let listRowRadius: CGFloat = 6
  static let listRowPaddingV: CGFloat = 3
  static let listRowPaddingH: CGFloat = 8
  static let listRowGap: CGFloat = 8
  /// The rail: a 36-point face on a 52 × 48 plate; an icon's plate is 36 high.
  static let railFace: CGFloat = 36
  static let railTile = CGSize(width: 52, height: 48)
  static let railIconHeight: CGFloat = 36
}
extension Palette {
  /// The boards' neutral washes (`--p03` to `--p15`): white over the dark palette, black over the
  /// light one.
  func wash(_ alpha: Double) -> Color { isDark ? Color.white.opacity(alpha) : Color.black.opacity(alpha) }
  /// A face's eyes: white on the light palette's deep tints, near-black on the dark palette's
  /// bright ones (`--av-eye`).
  var faceEye: Color { isDark ? Color(hex: 0x0A0A0A) : Color.white }
  /// The soft lift under an assistant card (`--shadow`).
  var cardShadow: Color { Color.black.opacity(isDark ? 0 : 0.05) }
}

extension View {
  /// The boards' card (`card20`): the `overlay` plane, a 1-point `line` edge and a soft lift.
  func assistantCard(_ p: Palette, radius: CGFloat = AssistantMetrics.cardRadius) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return background(p.overlay, in: shape)
      .shadow(color: p.cardShadow, radius: 14, y: 6)
  }
}

/// Click feedback every button shares: it shrinks to 0.97 in 0.06 seconds while pressed; nothing
/// moves under Reduce Motion.
struct PressFeedback: ViewModifier {
  let pressed: Bool
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  func body(content: Content) -> some View {
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    content
      .scaleEffect(pressed && !reduce ? Motion.pressScale : 1)
      .animation(reduce ? nil : Motion.press, value: pressed)
  }
}

/// A message bubble under the pointer: a small shift in brightness, away from the background.
struct ChatBubbleHover: ViewModifier {
  @State private var hovered = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  func body(content: Content) -> some View {
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    content
      .brightness(hovered ? (p.isDark ? 0.04 : -0.03) : 0)
      .animation(reduce ? nil : .easeOut(duration: Motion.releaseDuration), value: hovered)
      .onHover { hovered = $0 }
  }
}

extension View {
  func pressFeedback(_ pressed: Bool) -> some View { modifier(PressFeedback(pressed: pressed)) }
}

/// `.plain` with the shared click feedback: a control that draws its own look still answers the press.
struct PlainPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.pressFeedback(configuration.isPressed)
  }
}
extension ButtonStyle where Self == PlainPressStyle {
  static var pressable: PlainPressStyle { PlainPressStyle() }
}

/// Hover and click on the personal-assistant screens: a control that draws its own surface fades a
/// little under the pointer and takes the shared click feedback.
struct AssistantPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { Pressed(configuration: configuration) }
  private struct Pressed: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sereinReducedEffects) private var previewReducedEffects
    var body: some View {
      let reduce: Bool = systemReduceMotion || previewReducedEffects
      configuration.label
        .contentShape(Rectangle())
        .opacity(hovered && enabled ? 0.78 : 1)
        .pressFeedback(configuration.isPressed)
        .animation(reduce ? nil : .easeOut(duration: Motion.releaseDuration), value: hovered)
        .onHover { hovered = $0 }
    }
  }
}

/// The shared header for library pages: title, a supporting line and trailing controls,
/// placed on the page gutter so every title starts at the same x position.
struct PageHeader<Trailing: View>: View {
  var title: String
  var subtitle: String?
  @ViewBuilder var trailing: () -> Trailing
  init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
  }
  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).role(.title).lineLimit(1).accessibilityAddTraits(.isHeader)
        if let subtitle, !subtitle.isEmpty { Text(subtitle).role(.meta).lineLimit(1) }
      }
      Spacer(minLength: 12)
      trailing()
    }.frame(minHeight: 44)
  }
}
extension PageHeader where Trailing == EmptyView {
  init(_ title: String, subtitle: String? = nil) {
    self.init(title, subtitle: subtitle) { EmptyView() }
  }
}
extension View {
  /// Library page frame: gutter, top inset and a centered column capped at `width`.
  func pageColumn(_ width: CGFloat = UIStyle.listWidth) -> some View {
    frame(maxWidth: width, alignment: .topLeading)
      .padding(.horizontal, UIStyle.pageGutter).padding(.top, UIStyle.pageTop)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

/// Displays a bundled icon with an SF Symbols fallback.
struct InterfaceIcon: View {
  let systemName: String
  var size: CGFloat = 16
  private static let names = [
    "plus": "plus", "xmark": "close",
    "arrow.up": "arrow-up", "arrow.down": "arrow-down", "arrow.left": "arrow-left",
    "arrow.right": "arrow-right", "arrow.up.right": "arrow-up-right",
    "chevron.left": "alt-arrow-left", "chevron.right": "alt-arrow-right",
    "chevron.down": "alt-arrow-down", "chevron.up": "alt-arrow-up",
    "stop.fill": "stop", "stop.circle": "stop", "mic": "microphone",
    "slider.horizontal.3": "tuning", "gearshape": "settings-minimalistic",
    "magnifyingglass": "magnifer", "folder": "folder", "folder.badge.plus": "folder-with-files",
    "square.and.pencil": "pen-new-square", "paperclip": "paperclip",
    "clock.arrow.circlepath": "clock-circle", "clock": "clock-circle",
    "calendar": "calendar", "bubble.left": "chat-round-line",
    "bubble.left.and.bubble.right": "chat-round-line", "globe": "globe",
    "eye.slash": "eye-closed", "list.bullet": "list", "square.grid.2x2": "widget",
    // Not a system symbol: only the bundled drawing (three squares and a plus) exists.
    "square.grid.2x2.badge.plus": "widget-add",
    "arrow.up.left.and.arrow.down.right": "expand-arrows", "sidebar.left": "split-columns",
    "arrow.clockwise": "refresh", "key": "key-minimalistic", "keyboard": "keyboard",
    "terminal": "terminal", "moon": "moon", "checkmark": "check",
    "ellipsis": "more-horizontal", "trash": "trash-bin-minimalistic", "doc.on.doc": "copy",
    "externaldrive": "hard-drive", "pin": "pin", "arrow.turn.down.left": "return",
    "info.circle": "info-circle", "eye": "eye", "exclamationmark.triangle": "danger-triangle",
    "brand.claude": "claude-mark", "brand.codex": "openai-mark",
    "harness.claude": "harness-claudecode", "harness.codex": "harness-codex",
    "harness.cursor": "harness-cursor", "harness.opencode": "harness-opencode",
    "harness.pi": "harness-pi", "harness.omp": "harness-ohmypi", "harness.grok": "harness-grok",
    // No mark is bundled for Gemini CLI: it shows the terminal glyph.
    "harness.gemini": "terminal",
    "serein.mark": "serein-mark",
  ]
  private static let assets: [String: NSImage] = Dictionary(uniqueKeysWithValues:
    Set(names.values).compactMap { name -> (String, NSImage)? in
      guard let url = Bundle.assets.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
        let asset = NSImage(contentsOf: url) else { return nil }
      // Native Menu labels also consume the AppKit image's template flag.
      asset.isTemplate = true
      return (name, asset)
    })
  var body: some View {
    if let name = Self.names[systemName], let asset = Self.assets[name]
    {
      Image(nsImage: asset).renderingMode(.template).resizable().scaledToFit()
        .frame(width: size, height: size)
    } else {
      Image(systemName: systemName).resizable().scaledToFit().frame(width: size, height: size)
    }
  }
}
extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255, opacity: 1)
  }
  init(wash: ThemeWash) {
    self.init(hex: wash.rgb)
    self = self.opacity(wash.alpha)
  }
}
extension NSColor {
  convenience init(hex: UInt32) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
      blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
}
/// Unset by default: views then draw with the palette that matches their effective appearance,
/// so every hosting view, sheet and popover follows Settings › General without wiring.
struct PaletteKey: EnvironmentKey { static let defaultValue: Palette? = nil }
/// `--ui-reduced-effects` is the default, so every hosting view, sheet and popover of a preview
/// holds still, and code with no view reads the same flag (`MessageMotion.reduced`).
struct ReducedEffectsKey: EnvironmentKey { static let defaultValue = CommandLine.arguments.contains("--ui-reduced-effects") }
struct SidebarRailKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var palette: Palette {
    get { self[PaletteKey.self] ?? (colorScheme == .dark ? .dusk : .light) }
    set { self[PaletteKey.self] = newValue }
  }
  /// Preview-only override; the real system accessibility settings always win.
  var sereinReducedEffects: Bool {
    get { self[ReducedEffectsKey.self] }
    set { self[ReducedEffectsKey.self] = newValue }
  }
  /// The one answer to "hold still?" for a view: the system's Reduce Motion, or the preview's flag.
  /// Code with no view asks `MessageMotion.reduced`, which reads the same two.
  var reducesMotion: Bool { accessibilityReduceMotion || sereinReducedEffects }
  /// The sidebar is its rail: its rows draw their picture alone (`WallSidebar`).
  var sidebarRail: Bool {
    get { self[SidebarRailKey.self] }
    set { self[SidebarRailKey.self] = newValue }
  }
}
struct QuietButton: ButtonStyle {
  /// An answer beside a primary one: Grok's `.cfg-btn--secondary`, the primary's capsule on `track`
  /// with a 0.5 `line` ring. Unbordered, Grok's `.link-btn`: the quiet link footers and toolbars use.
  var bordered = false
  func makeBody(configuration: Configuration) -> some View {
    ButtonSurface(pressed: configuration.isPressed, primary: false, bordered: bordered) { configuration.label }
  }
}
/// Quiet hover wash for rows and labels; carries its own hovered state so row-builder
/// funcs stay funcs. Matches the app's p.hover token and motion rules.
struct HoverWash<S: Shape>: ViewModifier {
  var shape: S
  @State private var hovered = false
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) var systemReduceMotion
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  func body(content: Content) -> some View {
    content
      .background(hovered ? p.hover : .clear, in: shape)
      .contentShape(shape)
      .onHover { hovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
  }
}
extension View {
  func hoverWash<S: Shape>(in shape: S) -> some View { modifier(HoverWash(shape: shape)) }
}
struct PrimaryButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    ButtonSurface(pressed: configuration.isPressed, primary: true) {
      configuration.label.font(UIStyle.font(13, weight: .medium))
    }
  }
}
/// A capsule button, for Serein's chat cards and the page capsule: `solid` is the primary plate
/// (white in dark, near-black in light), `tinted` the `track` capsule, `quiet` bare until hovered.
/// Grok's `.btn`: regular 36 high at 14 medium, small 32 at 13 regular.
struct PillButton: ButtonStyle {
  enum Kind { case solid, tinted, quiet }
  var kind: Kind = .tinted
  var small = false
  func makeBody(configuration: Configuration) -> some View {
    PillSurface(configuration: configuration, kind: kind, small: small)
  }
  private struct PillSurface: View {
    let configuration: ButtonStyleConfiguration
    let kind: Kind
    let small: Bool
    @State private var hovered = false
    @Environment(\.palette) var p
    @Environment(\.isEnabled) var enabled
    @Environment(\.accessibilityReduceMotion) var systemReduceMotion
    @Environment(\.sereinReducedEffects) var previewReducedEffects
    var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
    var filled: Bool { kind == .solid }
    var body: some View {
      let pressed = configuration.isPressed
      configuration.label
        .font(UIStyle.font(small ? 13 : 14, weight: small || kind == .quiet ? .regular : .medium))
        .foregroundStyle(filled ? p.onSolid : p.ink)
        .padding(.horizontal, small ? 12 : 16).frame(height: small ? 32 : 36)
        .background {
          switch kind {
          case .solid: Capsule().fill(p.solid.opacity(pressed ? 0.8 : 1))
          case .tinted: Capsule().fill(pressed ? p.selected : hovered ? p.hover : p.track)
          case .quiet: Capsule().fill(pressed ? p.selected : hovered ? p.hover : Color.clear)
          }
        }
        .overlay(Capsule().strokeBorder(filled ? p.edge : Color.clear, lineWidth: UIStyle.hairline))
        .keyboardFocusRing(Capsule())
        .contentShape(Capsule())
        .brightness(filled && hovered && enabled ? 0.055 : 0)
        .opacity(enabled ? 1 : 0.4)
        .pressFeedback(pressed)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
    }
  }
}
private struct ButtonSurface<Content: View>: View {
  var pressed: Bool
  var primary: Bool
  var bordered = false
  @ViewBuilder var content: () -> Content
  @State private var hovered = false
  @Environment(\.palette) var p
  @Environment(\.isEnabled) var enabled
  @Environment(\.accessibilityReduceMotion) var systemReduceMotion
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  var body: some View {
    let pill = primary || bordered
    let shape = RoundedRectangle(cornerRadius: pill ? 15 : UIStyle.controlRadius, style: .continuous)
    // Grok's `.cfg-btn` (30 high capsule, 13 on 18) for the primary and bordered; `.link-btn` bare.
    content()
      .font(UIStyle.font(13, weight: primary ? .medium : .regular)).tracking(pill ? 0.1 : 0)
      .padding(.horizontal, pill ? 12 : 6).padding(.vertical, pill ? 0 : 4).frame(minHeight: pill ? 30 : nil)
      .contentShape(shape)
      .foregroundStyle(primary ? p.onSolid : bordered || hovered ? p.ink : p.secondary)
      .background(
        primary
          ? p.solid.opacity(pressed ? 0.8 : 1)
          : bordered ? (pressed || hovered ? p.selected : p.track)
          : (pressed ? p.selected : hovered ? p.hover : Color.clear),
        in: shape
      )
      .overlay(shape.strokeBorder(primary ? p.edge : bordered ? p.line : Color.clear, lineWidth: UIStyle.hairline))
      .keyboardFocusRing(shape)
      .brightness(primary && hovered && enabled ? 0.055 : 0)
      .opacity(enabled ? 1 : 0.45)
      .pressFeedback(pressed)
      .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.12), value: hovered)
      .onHover { hovered = $0 }
  }
}
struct SereinMark: View {
  var size: CGFloat = 30
  /// The petal's colour; nil is the accent, Serein's own.
  var color: Color? = nil
  @Environment(\.palette) var p
  var body: some View {
    let ink = color ?? p.accent
    ZStack {
      ForEach(0..<5) { i in
        Ellipse().stroke(ink, lineWidth: 1.3).frame(width: size * 0.4, height: size * 0.86)
          .rotationEffect(.degrees(Double(i) * 36))
      }
      Circle().fill(ink).frame(width: 4, height: 4)
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}
/// What an assistant's mark does for its state (`RelayOrchestrator.assistantStatus`): Ready, idle,
/// paused or offline hold still.
enum AssistantMarkMotion: Equatable {
  case still, working, needsYou, unread
  init(_ status: SereinStatus) {
    switch status {
    case .replying, .working: self = .working
    case .needsYou: self = .needsYou
    case .unread: self = .unread
    case .notConnected, .offline, .ready, .paused: self = .still
    }
  }
}
/// An assistant's mark: its face (`AssistantFace`, AssistantFaceView.swift) in its tint
/// (`ThemeTokens.assistantTints`), or its own icon (`RelayProfile.icon`: an emoji, a symbol or a
/// picture) inside a ring of that tint, so tints still tell assistants apart. The main assistant
/// shows Serein's app icon. With no assistant named (`owner` nil: a proposal, a starter, the next
/// free tint) it is the petal. `motion` shows its state: a working face blinks and lifts (the
/// petal turns once in 6 seconds; an icon's ring and the app icon's glow instead), Needs you pulses
/// an amber ring, a new reply bounces once and leaves an accent dot. Repeating motion is Core
/// Animation's (LayerMotion.swift, AssistantFaceView.swift) and only while a state asks for it;
/// under Reduce Motion the same colours stand still as a ring or the dot.
struct AssistantMark: View {
  /// The profile's colour key (`RelayProfile.colour`).
  var tint: String?
  var size: CGFloat = 16
  /// nil is the petal.
  var icon: AssistantIcon? = nil
  /// The assistant whose folder a picture is read from.
  var owner: String? = nil
  var motion: AssistantMarkMotion = .still
  @State private var lifted = false
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  private var ringWidth: CGFloat { max(1, (size * 0.07).rounded()) }
  private var dot: CGFloat { min(8, max(4, size * 0.28)) }
  /// The picture, when the icon is one and its file is there; a missing one shows the petal.
  private var picture: NSImage? {
    guard let name = icon?.pictureFile, let owner else { return nil }
    return AssistantPictures.image(name, owner: owner)
  }
  var body: some View {
    let ink = p.assistantTint(tint)
    let image = picture
    let ringed: Bool = icon != nil && (icon?.pictureFile == nil || image != nil)
    let scale: CGFloat = lifted ? 1.18 : 1
    ZStack {
      face(ink, image, ringed: ringed)
      stateRing(ink, ringed: ringed)
    }
    .frame(width: size, height: size)
    .overlay(alignment: .topTrailing) { unreadDot }
    .scaleEffect(scale)
    .onChange(of: motion) { _, now in bounce(now) }
    .accessibilityHidden(true)
  }
  /// The main assistant's app icon (it is Serein).
  private var isMain: Bool { owner == RelayTeam.mainID }
  /// The icon in its tint ring; else Serein's app icon for the main assistant and the face
  /// (`AssistantFace`) for every other one; the petal only where no assistant is named yet (a
  /// proposal, a starter, the next free tint).
  @ViewBuilder private func face(_ ink: Color, _ image: NSImage?, ringed: Bool) -> some View {
    if ringed {
      iconFace(ink, image)
      Circle().strokeBorder(ink, lineWidth: ringWidth)
    } else if isMain {
      SereinAppIconImage(size: size)
    } else if let owner {
      AssistantFaceView(face: AssistantFaces.face(for: owner, wearing: tint), size: size, working: motion == .working)
    } else if motion == .working && !reduceMotion {
      TurningPetal(color: ink, size: size)
    } else {
      SereinMark(size: size, color: ink)
    }
  }
  @ViewBuilder private func iconFace(_ ink: Color, _ image: NSImage?) -> some View {
    switch icon {
    case .emoji(let text)?:
      Text(verbatim: text).font(.system(size: size * 0.56)).lineLimit(1).fixedSize()
    case .symbol(let name)?:
      InterfaceIcon(systemName: name, size: size * 0.5).foregroundStyle(ink)
    default:
      if let image {
        let inner: CGFloat = size - ringWidth * 2
        Image(nsImage: image).resizable().scaledToFill().frame(width: inner, height: inner).clipShape(Circle())
      }
    }
  }
  /// The state's ring: a glowing tint ring while it works (an icon's and the app icon's; a face
  /// blinks and the petal turns instead), an amber one while it needs you; still under Reduce Motion.
  @ViewBuilder private func stateRing(_ ink: Color, ringed: Bool) -> some View {
    switch motion {
    case .working:
      if reduceMotion {
        let glow: CGFloat = max(1.5, size * 0.08)
        Circle().strokeBorder(ink, lineWidth: ringWidth).shadow(color: ink.opacity(0.8), radius: glow)
      } else if ringed || isMain {
        PulsingRing(color: ink, lineWidth: ringWidth, period: 2.4, glow: true)
      }
    case .needsYou:
      if reduceMotion {
        Circle().strokeBorder(p.warning, lineWidth: ringWidth)
      } else {
        PulsingRing(color: p.warning, lineWidth: ringWidth, period: 1.6)
      }
    case .still, .unread:
      EmptyView()
    }
  }
  @ViewBuilder private var unreadDot: some View {
    if motion == .unread {
      let offset: CGFloat = dot * 0.3
      Circle().fill(p.accent).frame(width: dot, height: dot).offset(x: offset, y: -offset)
    }
  }
  /// One small bounce when a reply arrives; the dot then stays still.
  private func bounce(_ now: AssistantMarkMotion) {
    guard now == .unread, !reduceMotion else { return }
    withAnimation(.easeOut(duration: 0.12)) { lifted = true } completion: {
      withAnimation(.spring(duration: 0.35, bounce: 0.5)) { lifted = false }
    }
  }
}
extension AssistantMark {
  /// A profile's mark: its tint and icon, moving by its state when one is given.
  init(profile: RelayProfile?, size: CGFloat, status: SereinStatus? = nil) {
    self.init(tint: profile?.colour, size: size, icon: profile?.icon, owner: profile?.id,
              motion: status.map { AssistantMarkMotion($0) } ?? .still)
  }
}
extension Palette {
  /// The colour an assistant's petal and swatch use in this appearance.
  func assistantTint(_ key: String?) -> Color { Color(hex: tokens.assistantTint(key)) }
}
/// The mark as the film draws it: five orbits that glow, a lit core and a faint dotted ring.
/// Its colors are fixed, because it sits on its own dark ground in both appearances.
struct SereinGlowMark: View {
  var size: CGFloat = 96
  private let glow = Color(hex: 0x7C86FF)
  private let light = Color(hex: 0xC9CEFF)
  var body: some View {
    ZStack {
      Circle().fill(RadialGradient(
        colors: [glow.opacity(0.42), glow.opacity(0.10), .clear], center: .center,
        startRadius: 0, endRadius: size * 0.78)
      ).frame(width: size * 1.6, height: size * 1.6)
      Circle().stroke(light.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [1, 5]))
        .frame(width: size * 1.36, height: size * 1.36)
      ForEach(0..<5) { i in
        Ellipse().stroke(
          LinearGradient(colors: [light, glow], startPoint: .top, endPoint: .bottom),
          lineWidth: max(1.4, size * 0.022)
        ).frame(width: size * 0.4, height: size * 0.86).rotationEffect(.degrees(Double(i) * 36))
      }.shadow(color: glow.opacity(0.9), radius: size * 0.06)
      Circle().fill(RadialGradient(
        colors: [.white, light, glow.opacity(0)], center: .center, startRadius: 0, endRadius: size * 0.07)
      ).frame(width: size * 0.14, height: size * 0.14)
    }.frame(width: size * 1.6, height: size * 1.6).accessibilityHidden(true)
  }
}

struct DarkGlass: ViewModifier {
  var radius: CGFloat = 10
  @Environment(\.accessibilityReduceTransparency) var systemReducedTransparency
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var reducedTransparency: Bool { systemReducedTransparency || previewReducedEffects }
  @Environment(\.palette) var p
  @ViewBuilder func body(content: Content) -> some View {
    if reducedTransparency {
      content.background(p.panel, in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(p.line, lineWidth: UIStyle.hairline))
    } else if #available(macOS 26.0, *) {
      content.glassEffect(
        .regular.tint(p.sidebar.opacity(0.80)),
        in: RoundedRectangle(cornerRadius: radius)
      )
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(
          LinearGradient(
            colors: p.isDark
              ? [Color.white.opacity(0.14), Color.white.opacity(0.08), Color.white.opacity(0.08)]
              : [Color.black.opacity(0.10), Color.black.opacity(0.05), Color.black.opacity(0.08)],
            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: UIStyle.hairline))
    } else {
      content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        .background(p.sidebar.opacity(0.8), in: RoundedRectangle(cornerRadius: radius))
        .overlay(
          RoundedRectangle(cornerRadius: radius).strokeBorder(p.line, lineWidth: UIStyle.hairline))
    }
  }
}
extension View {
  func darkGlass(_ radius: CGFloat = UIStyle.panelRadius) -> some View { modifier(DarkGlass(radius: radius)) }
}
/// The ⌥Space bar's surface, and its reply card's: glass that shows the app behind, under `panel`
/// at `fill`. Glass alone takes the tone of the page behind it: a dark bar over a white page went
/// light grey, and `ink` measured 1.27:1 on it. At 0.8, over a white and over a black page in both
/// palettes, `ink` measures 8.2:1 or more, `secondary` 4.0 and `danger` 3.6. Opaque `panel` when
/// the Mac reduces transparency.
struct BarGlass<S: Shape>: ViewModifier {
  var shape: S
  let fill = 0.8
  @Environment(\.accessibilityReduceTransparency) var systemReducedTransparency
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  @Environment(\.palette) var p
  @ViewBuilder func body(content: Content) -> some View {
    if systemReducedTransparency || previewReducedEffects {
      content.background(p.panel, in: shape)
    } else if #available(macOS 26.0, *) {
      content.background(p.panel.opacity(fill), in: shape).glassEffect(.regular, in: shape)
    } else {
      content.background(p.panel.opacity(fill), in: shape).background(.ultraThinMaterial, in: shape)
    }
  }
}
extension View {
  func barGlass<S: Shape>(in shape: S) -> some View { modifier(BarGlass(shape: shape)) }
}
struct AmbientBackground: View {
  @Environment(\.palette) var p
  var body: some View {
    p.sidebar.allowsHitTesting(false).accessibilityHidden(true)
  }
}
