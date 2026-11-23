import SereinCore
import SwiftUI

/// A settings card: a small uppercase caption above an opaque card. Controls inside sit 16 points
/// apart; a `SettingsNote` tucks in 4 points under the control it explains.
struct SettingsGroup<Content: View>: View {
  var title: String
  var info: String?
  @ViewBuilder var content: () -> Content
  init(_ title: String, info: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.info = info
    self.content = content
  }
  @Environment(\.palette) var p
  @Environment(\.settingsSectionTitle) private var section
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !repeatsSection(title, section) || info != nil {
        // A caption in 12 `secondary`, as every other Settings caption (no capitals, no weight).
        HStack(spacing: 4) {
          if !repeatsSection(title, section) {
            Text(verbatim: title).font(AssistantType.meta).foregroundStyle(p.secondary)
              .padding(.leading, 2).accessibilityAddTraits(.isHeader)
          }
          if let info { InfoPopoverButton(text: info, label: "About \(title.lowercased())") }
        }
      }
      VStack(alignment: .leading, spacing: 16, content: content).font(UIStyle.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).settingsCard()
    }.id(title)
  }
}

/// Help text under a control: meta size, secondary color, 4 points below the control.
struct SettingsNote: View {
  var text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).role(.meta).fixedSize(horizontal: false, vertical: true).padding(.top, -12)
  }
}

/// Settings booleans: label on the leading edge, a mini switch on the trailing edge.
struct SettingsToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .center, spacing: 12) {
      configuration.label.frame(maxWidth: .infinity, alignment: .leading).accessibilityHidden(true)
      // The switch keeps the label for VoiceOver; only its visual copy is hidden.
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .toggleStyle(SereinSwitchStyle(labeled: false))
    }.contentShape(Rectangle())
  }
}

/// The on-off switch, on `solid` while on: white in dark, near-black in light. AppKit's own switch
/// draws a white tint as gray, which reads as off. VoiceOver is given the native switch.
struct SereinSwitchStyle: ToggleStyle {
  /// False draws the switch alone: `labelsHidden()` does not reach a custom style. VoiceOver reads
  /// the label either way.
  var labeled = true
  func makeBody(configuration: Configuration) -> some View { SereinSwitch(configuration: configuration, labeled: labeled) }
}

private struct SereinSwitch: View {
  let configuration: ToggleStyleConfiguration
  let labeled: Bool
  /// Grok's `.toggle`: 32 by 20, a 16 white knob, the primary plate when on.
  private static let width: CGFloat = 32
  private static let height: CGFloat = 20
  private static let inset: CGFloat = 2
  @Environment(\.palette) private var p
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// A locked row dims as a whole (`settingsLocked`), so the switch does not dim again inside it.
  @Environment(\.settingsRowLocked) private var locked
  private var on: Bool { configuration.isOn }
  var body: some View {
    let knob = Self.height - Self.inset * 2
    HStack(spacing: 8) {
      if labeled { configuration.label }
      Button { configuration.isOn.toggle() } label: {
        Capsule().fill(on ? p.solid : p.track)
          .overlay(Capsule().strokeBorder(on ? Color.clear : p.line, lineWidth: UIStyle.hairline))
          .frame(width: Self.width, height: Self.height)
          .overlay(alignment: .leading) {
            Circle().fill(on ? p.onSolid : Color.white).frame(width: knob, height: knob)
              .shadow(color: Color(hex: 0x1C1C1C).opacity(0.12), radius: 1.5, y: 1)
              .offset(x: on ? Self.width - knob - Self.inset : Self.inset)
          }
          .keyboardFocusRing(Capsule())
          .opacity(enabled || locked ? 1 : 0.4)
          .contentShape(Capsule())
      }.buttonStyle(.pressable)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.2), value: on)
        .accessibilityRepresentation {
          Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
  }
}

/// A small info glyph that shows a longer explanation in a popover.
struct InfoPopoverButton: View {
  var text: String
  var label = "More information"
  @State private var open = false
  @Environment(\.palette) var p
  var body: some View {
    Button { open.toggle() } label: {
      InterfaceIcon(systemName: "info.circle", size: 13).foregroundStyle(p.secondary)
        .frame(width: 20, height: 20).contentShape(Rectangle())
    }.buttonStyle(.pressable).help(label).accessibilityLabel(label)
      .popover(isPresented: $open, arrowEdge: .bottom) {
        Text(text).font(UIStyle.meta).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true).frame(width: 300, alignment: .leading)
          .padding(14)
      }
  }
}

private struct SettingsRowLockedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var settingsRowLocked: Bool {
    get { self[SettingsRowLockedKey.self] }
    set { self[SettingsRowLockedKey.self] = newValue }
  }
}

extension View {
  /// A row that cannot change now: the row at 40% and disabled, with why in a few words under it
  /// at full strength ("Serein's computer is off"). VoiceOver hears the reason as the hint. Nil
  /// leaves the row as it is.
  func settingsLocked(_ reason: String?) -> some View { modifier(SettingsLock(reason: reason)) }
}
private struct SettingsLock: ViewModifier {
  let reason: String?
  func body(content: Content) -> some View {
    if let reason {
      VStack(alignment: .leading, spacing: 4) {
        content.disabled(true).opacity(0.4).environment(\.settingsRowLocked, true)
        Text(verbatim: reason).role(.meta).fixedSize(horizontal: false, vertical: true)
      }.accessibilityElement(children: .combine).accessibilityHint(reason)
    } else {
      content
    }
  }
}

/// Revert and Save for a page that saves at all, shown only while something is unsaved: a page
/// with nothing changed has no dead buttons. A refusal from the last Save shows in `danger` at its
/// leading edge. `subject` finishes VoiceOver's labels ("Save the job and the instructions").
struct SettingsSaveBar: View {
  let changed: Bool
  var problem: String?
  var subject = "the changes"
  let revert: () -> Void
  let save: () -> Void
  @Environment(\.palette) private var p
  var body: some View {
    if changed {
      HStack(spacing: 8) {
        if let problem { Text(verbatim: problem).font(AssistantType.meta).foregroundStyle(p.danger).lineLimit(2) }
        Spacer(minLength: 0)
        Button("Revert", action: revert).buttonStyle(QuietButton())
          .accessibilityLabel("Revert \(subject) to the saved ones")
        Button("Save", action: save).buttonStyle(PrimaryButton())
          .keyboardShortcut(.return, modifiers: .command)
          .accessibilityLabel("Save \(subject)")
      }
    }
  }
}

/// A settings place that is loading (`LoadingStage`): nothing for the first 0.2 seconds, so a
/// fast load never flashes, then skeleton lines (`SkeletonBar`), then from 8 seconds one plain
/// line that it is slow, with Try again when the place can start over. Each stage swaps in at
/// once; the blank stage keeps the skeleton's room, so nothing below it moves at 0.2 seconds.
struct SettingsLoading: View {
  var lines = 2
  var retry: (() -> Void)?
  @State private var stage = LoadingStage.blank
  @State private var attempt = 0
  var body: some View {
    Group {
      if stage == .slow {
        HStack(spacing: 8) {
          Text("Taking longer than usual.").role(.meta)
          if let retry {
            Button("Try again") {
              stage = .blank
              attempt += 1
              retry()
            }.buttonStyle(QuietButton())
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(0..<max(1, lines), id: \.self) { line in
            SkeletonBar(width: line == lines - 1 && lines > 1 ? 160 : nil, height: 12)
          }
        }.opacity(stage == .skeleton ? 1 : 0)
          .accessibilityElement().accessibilityLabel("Loading")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: attempt) {
      let start: ContinuousClock.Instant = .now
      for moment in LoadingStage.moments {
        do { try await Task.sleep(until: start + .seconds(moment), clock: .continuous) } catch { return }
        stage = LoadingStage(waited: moment)
      }
    }
  }
}
