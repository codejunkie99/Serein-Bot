import SwiftUI

/// The message bar's mic. A click sends a ring out from it and the glyph springs; while the
/// microphone opens an arc circles it; while it listens it turns red, swells with the voice and
/// sends out soft ripples. Reduce Motion keeps only the colour.
struct MicOrb: View {
  @ObservedObject var dictation: Dictation
  let toggle: () -> Void
  @State private var bursts: [MicBurst.Ring] = []
  @State private var nextBurst = 0
  @State private var kicked = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sereinReducedEffects) private var reducedEffects
  /// The button's side, the same as the bar's other icons.
  static let side: CGFloat = 28
  /// How long a click's ring takes to fade out.
  static let burstLife: Duration = .milliseconds(700)
  /// How long the glyph stays enlarged after a click before it springs back.
  static let kickLife: Duration = .milliseconds(120)

  private var still: Bool { reduceMotion || reducedEffects }
  private var on: Bool { dictation.recording || dictation.starting }
  private var glyphTint: Color {
    if dictation.recording { return .white }
    return on ? p.ink : p.secondary
  }

  var body: some View {
    Button {
      fire()
      toggle()
    } label: {
      ZStack {
        if dictation.recording {
          MicVoiceGlow(meter: dictation.meter, tint: p.danger, still: still)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
        if dictation.starting && !still {
          MicStartArc(tint: p.ink).transition(.opacity)
        }
        InterfaceIcon(systemName: on ? "mic.fill" : "mic", size: 15)
          .foregroundStyle(glyphTint)
          .scaleEffect(kicked ? 1.22 : 1)
      }
      .frame(width: Self.side, height: Self.side)
      .overlay {
        ForEach(bursts) { ring in MicBurst(ring: ring) }
      }
      .animation(still ? nil : .spring(response: 0.34, dampingFraction: 0.62), value: dictation.recording)
      .animation(still ? nil : .easeOut(duration: 0.2), value: dictation.starting)
    }
    .buttonStyle(GlyphButtonStyle())
    .help(on ? "Stop listening" : "Dictate")
    .accessibilityLabel(on ? "Stop listening" : "Dictate")
    .accessibilityValue(dictation.starting ? "Starting" : "")
  }

  /// A ring out from the button, red as the mic opens and grey as it closes, and a spring of
  /// the glyph.
  private func fire() {
    guard !still else { return }
    let ring = MicBurst.Ring(id: nextBurst, tint: on ? p.secondary : p.danger)
    nextBurst += 1
    bursts.append(ring)
    withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { kicked = true }
    Task { @MainActor in
      try? await Task.sleep(for: Self.kickLife)
      withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { kicked = false }
      try? await Task.sleep(for: Self.burstLife)
      bursts.removeAll { $0.id == ring.id }
    }
  }
}

/// One click's ring: it widens from the button and fades.
private struct MicBurst: View {
  struct Ring: Identifiable {
    let id: Int
    let tint: Color
  }
  let ring: Ring
  @State private var gone = false
  var body: some View {
    Circle().strokeBorder(ring.tint, lineWidth: 1.5)
      .scaleEffect(gone ? 2.3 : 0.9)
      .opacity(gone ? 0 : 0.8)
      .onAppear { withAnimation(.easeOut(duration: 0.6)) { gone = true } }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// While the microphone opens: a short arc going round the button.
private struct MicStartArc: View {
  let tint: Color
  @State private var turning = false
  var body: some View {
    Circle().trim(from: 0, to: 0.28)
      .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      .padding(1)
      .rotationEffect(.degrees(turning ? 360 : 0))
      .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true } }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// While it listens: a red disc that swells with the voice over a soft glow, and two ripples
/// that travel out further the louder the voice. It alone watches the meter, so the rest of the
/// bar never redraws at the meter's rate.
private struct MicVoiceGlow: View {
  @ObservedObject var meter: DictationMeter
  let tint: Color
  let still: Bool
  /// Seconds for one ripple to travel out.
  static let ripplePeriod: Double = 1.6
  static let rippleCount = 2

  var body: some View {
    let level = CGFloat(min(max(meter.level, 0), 1))
    ZStack {
      if !still {
        TimelineView(.animation) { context in
          let time = context.date.timeIntervalSinceReferenceDate
          ZStack {
            ForEach(0..<Self.rippleCount, id: \.self) { index in
              let phase = (time / Self.ripplePeriod + Double(index) / Double(Self.rippleCount))
                .truncatingRemainder(dividingBy: 1)
              Circle().stroke(tint.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                .scaleEffect(1 + CGFloat(phase) * (0.55 + level * 0.65))
            }
          }
        }
        Circle().fill(tint).blur(radius: 6)
          .opacity(0.25 + Double(level) * 0.5)
          .scaleEffect(1.05 + level * 0.4)
      }
      Circle().fill(tint)
        .scaleEffect(still ? 1 : 0.9 + level * 0.32)
        .animation(still ? nil : .spring(response: 0.18, dampingFraction: 0.7), value: level)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
