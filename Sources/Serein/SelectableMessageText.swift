import AppKit
import SwiftUI

func messageNativeFont(size: CGFloat, weight: Font.Weight = .regular, mono: Bool = false, textScale: CGFloat? = nil) -> NSFont {
  let scale = textScale ?? UIStyle.textScale
  let face: NSFont.Weight = weight == .bold ? .bold : weight == .semibold ? .semibold : weight == .medium ? .medium : .regular
  return mono ? NSFont.monospacedSystemFont(ofSize: size * scale, weight: face) : NSFont.systemFont(ofSize: size * scale, weight: face)
}

/// Inputs that affect native glyphs or colors. AttributedString keeps per-run code/link
/// styling; the key also covers plain text, which carries no explicit font or ink.
struct MessageNativeTextStyle: Equatable {
  var size: CGFloat = 14
  var weight: Font.Weight = .regular
  var mono = false
  var lineSpacing: CGFloat = 0
  var textScale: CGFloat = UIStyle.textScale
  var ink: Color
  var strong: Font.Weight = .semibold
}

private struct MessageRunFontKey: Hashable {
  let weight: Font.Weight
  let mono: Bool
  let italic: Bool
}

@MainActor final class MessageNativeTextRenderer {
  private var text: AttributedString?
  private var style: MessageNativeTextStyle?

  /// nil means the existing NSTextStorage is already correct. Keep the Swift value
  /// rather than rebuilding every native run merely to compare the resulting string.
  func render(_ text: AttributedString, style: MessageNativeTextStyle) -> NSAttributedString? {
    guard self.text != text || self.style != style else { return nil }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = style.lineSpacing
    // One source buffer, rather than allocating and appending a substring for every
    // styled run. Run attributes never change character order or UTF-16 selection offsets.
    let native = NSMutableAttributedString(string: String(text.characters))
    native.beginEditing()
    var fonts: [MessageRunFontKey: NSFont] = [:]
    var colors: [Color: NSColor] = [:]
    func nativeColor(_ color: Color) -> NSColor {
      if let cached = colors[color] { return cached }
      let result = NSColor(color)
      if colors.count < 16 { colors[color] = result }
      return result
    }
    var offset = 0
    for run in text.runs {
      let intent = run.inlinePresentationIntent ?? []
      let runWeight = intent.contains(.stronglyEmphasized) && style.weight != .bold ? style.strong : style.weight
      let fontKey = MessageRunFontKey(weight: runWeight, mono: style.mono || intent.contains(.code),
        italic: intent.contains(.emphasized))
      let font: NSFont
      if let cached = fonts[fontKey] { font = cached }
      else {
        let base = messageNativeFont(size: style.size, weight: runWeight,
          mono: fontKey.mono, textScale: style.textScale)
        font = fontKey.italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        fonts[fontKey] = font
      }
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: nativeColor(run.foregroundColor ?? style.ink), .paragraphStyle: paragraph,
      ]
      if let background = run.backgroundColor { attributes[.backgroundColor] = nativeColor(background) }
      if let link = run.link {
        attributes[.link] = link
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
      }
      let length = text[run.range].unicodeScalars.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
      native.setAttributes(attributes, range: NSRange(location: offset, length: length))
      offset += length
    }
    native.endEditing()
    self.text = text
    self.style = style
    return native
  }
}

/// Keep Markdown's existing run styling with native selection and a shared reply selection.
struct SelectableMessageText: NSViewRepresentable {
  var text: AttributedString
  var size: CGFloat = 14
  var weight: Font.Weight = .regular
  var strong: Font.Weight = .semibold
  var mono = false
  var lineSpacing: CGFloat = 0
  var selectionOrder: [Int] = []
  var selectionSeparator = "\n\n"
  /// As wide as its words, for a short message in a bubble. Measures twice, so never for long answers.
  var hugs = false
  @Environment(\.palette) private var p
  @Environment(\.openURL) private var openURL
  @Environment(\.messageSelection) private var messageSelection

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> MessageTextHost {
    let host = MessageTextHost()
    let view = host.textView
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor,
      .foregroundColor: NSColor.selectedTextColor]
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.isVerticallyResizable = false
    view.isHorizontallyResizable = false
    view.textContainer?.widthTracksTextView = true
    view.delegate = context.coordinator
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    updateNSView(host, context: context)
    return host
  }
  func updateNSView(_ host: MessageTextHost, context: Context) {
    let view = host.textView
    view.suppressMessageSelectionUpdates = true
    defer { view.suppressMessageSelectionUpdates = false }
    context.coordinator.content = self
    if let messageSelection {
      messageSelection.register(view, order: selectionOrder, separator: selectionSeparator)
    } else { view.messageSelection?.unregister(view) }
    // Link styling before the words: setting it redraws the whole text, which on a new view
    // (no width yet) lays every glyph out on a line of its own.
    let links: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(p.ink), .underlineStyle: NSUnderlineStyle.single.rawValue]
    if !NSDictionary(dictionary: view.linkTextAttributes ?? [:]).isEqual(to: links) { view.linkTextAttributes = links }
    let style = MessageNativeTextStyle(size: size, weight: weight, mono: mono,
      lineSpacing: lineSpacing, textScale: UIStyle.textScale, ink: p.ink, strong: strong)
    if let native = context.coordinator.renderer.render(text, style: style) {
      // Unrelated updates never replace storage or clear the person's selection.
      let selection = view.selectedRange()
      view.textStorage?.setAttributedString(native)
      if selection.location > 0 || selection.length > 0 {
        let start = min(selection.location, native.length)
        view.setSelectedRange(NSRange(location: start, length: min(selection.length, native.length - start)))
      }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextHost, context: Context) -> CGSize? {
    let view = nsView.textView
    // A stack asks for the narrowest size to rank its children: no width at all. Laying the
    // words out at zero width puts every glyph on a line of its own, the costliest layout there is.
    if let probe = proposal.width, probe < 1 { return CGSize(width: max(0, probe), height: 0) }
    // Wrapped prose already has a width. Finding its unwrapped width first can cost
    // more than the entire wrapped layout, especially on a long answer.
    let measurement = NativeTextMeasurement.forView(view)
    let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
    let width = proposed.map { hugs ? min($0, measurement.naturalWidth()) : $0 } ?? measurement.naturalWidth()
    return CGSize(width: width, height: measurement.height(width: width))
  }
  static func dismantleNSView(_ nsView: MessageTextHost, coordinator: Coordinator) {
    nsView.textView.messageSelection?.unregister(nsView.textView)
    NativeTextMeasurement.release(forView: nsView.textView)
    nsView.textView.delegate = nil
  }
  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var content: SelectableMessageText
    let renderer = MessageNativeTextRenderer()
    init(_ content: SelectableMessageText) { self.content = content }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let view = notification.object as? MessageTextView else { return }
      view.messageSelection?.nativeSelectionDidChange(in: view)
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }) else { return false }
      content.openURL(url)
      return true
    }
  }
}

/// SwiftUI sizes the neutral host; TextKit's intrinsic-size invalidations stay inside it.
final class MessageTextHost: NSView {
  let textView: MessageTextView
  init() {
    let storage = NSTextStorage()
    let layout = MessageLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 0, height: 100_000_000))
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    textView = MessageTextView(frame: .zero, textContainer: container)
    super.init(frame: .zero)
    textView.translatesAutoresizingMaskIntoConstraints = true
    textView.autoresizingMask = [.width, .height]
    addSubview(textView)
  }
  required init?(coder: NSCoder) { return nil }
  override func layout() {
    super.layout()
    if textView.frame != bounds { textView.frame = bounds }
  }
}

struct MessageCopyButton: View {
  let text: String
  var isVisible = true
  @State private var copied = false
  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      copied = NSPasteboard.general.setString(text, forType: .string)
    } label: {
      InterfaceIcon(systemName: copied ? "checkmark" : "doc.on.doc", size: 14)
        .frame(width: 18, height: 18)
    }.buttonStyle(QuietButton())
      .accessibilityLabel(copied ? "Message copied" : "Copy message")
      .opacity(isVisible ? 1 : 0)
      .allowsHitTesting(isVisible)
      .accessibilityHidden(!isVisible)
      .task(id: copied) {
        if copied {
          try? await Task.sleep(for: .seconds(2))
          if !Task.isCancelled { copied = false }
        }
      }
  }
}

