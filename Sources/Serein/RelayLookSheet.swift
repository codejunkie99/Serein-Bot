import SereinCore
import SwiftUI

/// Serein's customise sheet, opened from the hologram in the panel's card: a colour, a look and a
/// large preview, held in a `RelayLookDraft` until Save. Save wears the choice the way Settings ›
/// Relay does (`relay.wear(_:by: .you)`); Cancel and close store nothing. Modelled on affectUI's
/// Dialog (header with close, Cancel then Save) and Color Picker (round swatches named for VoiceOver).
struct RelayLookSheet: View {
  @ObservedObject var relay: RelayOrchestrator
  let name: String
  let close: () -> Void
  @State private var draft: RelayLookDraft
  @State private var saving = false
  @State private var problem: String?
  @Environment(\.palette) private var p

  init(relay: RelayOrchestrator, worn: RelayLook, name: String, close: @escaping () -> Void) {
    self.relay = relay
    self.name = name
    self.close = close
    var draft = RelayLookDraft(worn: worn)
    // `--ui-avatar-customise`: one look and one colour chosen, unsaved.
    let presets: [RelayLook] = RelayLook.presets
    if CommandLine.arguments.contains("--ui-avatar-customise"), presets.count > 3 {
      draft.choose(presets[3])
      draft.choose(presets[2].palette)
    }
    _draft = State(initialValue: draft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Customise \(name)").font(UIStyle.font(16, weight: .medium)).foregroundStyle(p.ink)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button(action: close) { InterfaceIcon(systemName: "xmark", size: 14).foregroundStyle(p.secondary) }
          .buttonStyle(.pressable).help("Close").accessibilityLabel("Close")
      }
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Colours").role(.meta)
          colours
          Text("Looks").role(.meta)
          looks
        }
        .frame(width: 300, alignment: .leading)
        preview.frame(maxWidth: .infinity)
      }
      HStack(spacing: 12) {
        if let problem { Text(problem).role(.meta).foregroundStyle(p.danger).lineLimit(2) }
        Spacer()
        Button("Cancel", action: close).buttonStyle(QuietButton(bordered: true)).keyboardShortcut(.cancelAction)
        Button(saving ? "Saving\u{2026}" : "Save", action: save).buttonStyle(PrimaryButton())
          .keyboardShortcut(.defaultAction).disabled(saving)
      }
    }
    .padding(16)
    .frame(width: 560)
    .background(p.panel)
  }

  private var colours: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        ForEach(Array(draft.colours.enumerated()), id: \.offset) { _, palette in
          let selected: Bool = draft.palette == palette
          Button { draft.choose(palette) } label: {
            Circle().fill(LinearGradient(colors: [Self.color(palette.primary), Self.color(palette.rim)], startPoint: .topLeading, endPoint: .bottomTrailing))
              .frame(width: 24, height: 24)
              .overlay(Circle().strokeBorder(p.borderStrong, lineWidth: 1).opacity(selected ? 0 : 1))
              .padding(2)
              .overlay(Circle().strokeBorder(p.ink, lineWidth: 2).opacity(selected ? 1 : 0))
              .contentShape(Circle())
          }
          .buttonStyle(.pressable)
          .accessibilityLabel(RelayLookDraft.name(of: palette))
          .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
      }
      .padding(2)
    }
    .accessibilityElement(children: .contain).accessibilityLabel("Colours")
  }

  /// "Design one", then each look drawn small with the drawn mark in its own colour: never a live
  /// hologram per tile, so the window keeps its one engine.
  private var looks: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .top, spacing: 12) {
        tile("Design one", selected: false, hint: "Asks \(name) in the chat to design a new look") {
          close()
          SereinRouter.show(draft: RelayLookDraft.designPrompt)
        } picture: {
          InterfaceIcon(systemName: "plus", size: 16).foregroundStyle(p.secondary)
        }
        ForEach(Array(draft.looks.enumerated()), id: \.offset) { _, look in
          tile(draft.title(of: look), selected: draft.look == look, hint: nil) { draft.choose(look) } picture: {
            SereinHologramMark(size: 36, tint: Self.color(look.palette.primary))
          }
        }
      }
      .padding(2)
    }
    .accessibilityElement(children: .contain).accessibilityLabel("Looks")
  }

  private func tile<Picture: View>(
    _ title: String, selected: Bool, hint: String?, action: @escaping () -> Void, @ViewBuilder picture: () -> Picture
  ) -> some View {
    Button(action: action) {
      VStack(spacing: 4) {
        picture()
          .frame(width: 56, height: 56)
          .background(p.track, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.ink, lineWidth: 2).opacity(selected ? 1 : 0))
        Text(title).font(UIStyle.font(11)).foregroundStyle(selected ? p.ink : p.secondary).lineLimit(1)
      }
      .frame(width: 60)
      .contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .accessibilityLabel(title)
    .accessibilityHint(hint ?? "")
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  /// The window's one hologram, wearing the unsaved choice; the panel's card draws the mark meanwhile.
  private var preview: some View {
    VStack(spacing: 12) {
      ChatTopHologramView(
        state: .idle, relay: relay, paused: false, needsYou: false, open: {}, help: name,
        look: (try? draft.chosen()) ?? draft.look)
        .frame(width: 180, height: 180)
      VStack(spacing: 2) {
        Text(verbatim: name).font(UIStyle.font(15, weight: .medium)).foregroundStyle(p.ink)
        Text(verbatim: draft.title(of: draft.look)).role(.meta)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func save() {
    saving = true
    problem = nil
    // A beat so Saving shows, then wear it the way Settings does.
    DispatchQueue.main.async {
      do {
        if let look = try draft.saved() { try relay.wear(look, by: .you) }
        close()
      } catch {
        problem = error.localizedDescription
        saving = false
      }
    }
  }

  private static func color(_ hex: String) -> Color { Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0) }
}
