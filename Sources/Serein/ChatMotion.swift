import AppKit
import SereinCore
import SwiftUI

/// The chat's small motions: a message's controls easing in on hover, the reply bar rising into
/// the composer, a message's time sliding in. Reduce Motion drops every movement and keeps the fades short.
@MainActor enum MessageMotion {
  /// The system's Reduce Motion or the preview's `--ui-reduced-effects`, as a view reads from
  /// `EnvironmentValues.reducesMotion`.
  static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ReducedEffectsKey.defaultValue }
  static var controls: Animation { reduced ? .linear(duration: 0.08) : .easeOut(duration: 0.16) }
  static var reply: Animation { reduced ? .linear(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.86) }
  static var time: Animation { reduced ? .linear(duration: 0.08) : .timingCurve(0.2, 0, 0, 1, duration: 0.16) }
}

/// A message control's glyph: a soft round wash under the pointer, a small press.
struct GlyphButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }
  private struct Face: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.palette) private var p
    var body: some View {
      configuration.label
        .background(Circle().fill(p.hover).opacity(hovered ? 1 : 0))
        .scaleEffect(configuration.isPressed ? 0.9 : 1)
        .contentShape(Circle())
        .onHover { hovered = $0 }
        .animation(MessageMotion.controls, value: hovered)
        .animation(MessageMotion.controls, value: configuration.isPressed)
    }
  }
}

/// A message's time beside its bubble, as Grok shows it: 12 `faint`, "9:02 AM", sliding 4 points in
/// from the bubble's side while the message is hovered.
struct MessageTime: View {
  let date: Date?
  let shown: Bool
  /// The person's messages sit on the right, so their time is on the bubble's left.
  let trailing: Bool
  @Environment(\.palette) private var p
  var body: some View {
    if let date {
      Text(date.formatted(date: .omitted, time: .shortened))
        .font(UIStyle.font(12)).tracking(0.12).foregroundStyle(p.faint).lineLimit(1).fixedSize()
        .padding(.bottom, 9)
        .opacity(shown ? 1 : 0).offset(x: shown ? 0 : trailing ? 4 : -4)
        .animation(MessageMotion.time, value: shown)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

/// Above the composer while a message is being replied to: whose it was, one line of it, and ×.
struct ReplyBar: View {
  let target: ReplyTarget
  let cancel: () -> Void
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 1.5).fill(p.accent).frame(width: 3, height: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(target.from == "you" ? "Replying to yourself" : "Replying to \(target.from)")
          .font(UIStyle.font(11, weight: .medium)).foregroundStyle(p.accent)
        Text(verbatim: DraftQuote.oneLine(target.text)).font(AssistantType.meta).foregroundStyle(p.secondary)
          .lineLimit(1).truncationMode(.tail)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Button(action: cancel) {
        InterfaceIcon(systemName: "xmark", size: 9).foregroundStyle(p.secondary).frame(width: 22, height: 22)
      }
      .buttonStyle(GlyphButtonStyle())
      .help("Don’t reply to it").accessibilityLabel("Stop replying")
    }
    .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
    .background(p.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.line, lineWidth: 1))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Replying to \(target.from): \(DraftQuote.oneLine(target.text))")
  }
}

/// Above a sent reply: the words it answered, as a small chip joined to the bubble by a hook.
struct ReplyQuoteChip: View {
  let quote: String
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: 5) {
      InterfaceIcon(systemName: "arrowshape.turn.up.left", size: 9).foregroundStyle(p.faint)
      Text(verbatim: DraftQuote.oneLine(quote)).font(UIStyle.font(11.5)).foregroundStyle(p.secondary)
        .lineLimit(1).truncationMode(.tail)
    }
    .padding(.horizontal, 9).frame(height: 22)
    .background(p.track, in: Capsule())
    .frame(maxWidth: AssistantMetrics.bubbleMax * 0.8, alignment: .trailing)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Replying to: \(quote)")
  }
}

/// ⌘V while the composer has the keyboard: `paste` takes a copied picture and says it did, and
/// the key goes no further; otherwise the text field pastes as usual.
struct PicturePaste: ViewModifier {
  let active: Bool
  let paste: () -> Bool
  @State private var monitor: Any?
  func body(content: Content) -> some View {
    content
      .onAppear { install() }
      .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
      .onChange(of: active) { _, _ in install() }
  }
  private func install() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    guard active else { return }
    let paste = paste
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
      return MainActor.assumeIsolated { paste() } ? nil : event
    }
  }
}

/// An answer to one of Serein's questions: a calm chip on the soft wash, ink words, a wash under
/// the pointer and a small press. `quiet`: Something else…, in grey and without the wash.
struct QuestionChipStyle: ButtonStyle {
  var quiet = false
  func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, quiet: quiet) }
  private struct Face: View {
    let configuration: ButtonStyleConfiguration
    let quiet: Bool
    @State private var hovered = false
    @Environment(\.palette) private var p
    var body: some View {
      configuration.label
        .font(UIStyle.font(13, weight: .medium))
        .foregroundStyle(quiet && !hovered ? p.secondary : p.ink)
        .padding(.horizontal, 13).frame(minHeight: 32)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(quiet ? (hovered ? p.track : .clear) : (hovered ? p.hover : p.track)))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(quiet ? p.line : .clear, lineWidth: 1))
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovered = $0 }
        .animation(MessageMotion.controls, value: hovered)
        .animation(MessageMotion.controls, value: configuration.isPressed)
    }
  }
}

/// A code panel's Copy, top right: the whole block to the clipboard, then "Copied" with a tick
/// for a moment so the click is seen.
struct CodeCopyButton: View {
  let text: String
  var label = "Copy code"
  @State private var copied = false
  @State private var reset: Task<Void, Never>?
  @Environment(\.palette) private var p
  /// How long "Copied" stays before the button reads Copy again.
  static let copiedFor: Duration = .milliseconds(1600)
  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      reset?.cancel()
      withAnimation(MessageMotion.controls) { copied = true }
      reset = Task { @MainActor in
        try? await Task.sleep(for: Self.copiedFor)
        guard !Task.isCancelled else { return }
        withAnimation(MessageMotion.controls) { copied = false }
      }
    } label: {
      HStack(spacing: 5) {
        InterfaceIcon(systemName: copied ? "checkmark" : "doc.on.doc", size: 11)
        Text(copied ? "Copied" : "Copy").font(UIStyle.font(11.5, weight: .medium))
      }.foregroundStyle(copied ? p.ink : p.secondary)
    }
    .buttonStyle(QuietButton())
    .help(label)
    .accessibilityLabel(copied ? "Copied" : label)
  }
}
